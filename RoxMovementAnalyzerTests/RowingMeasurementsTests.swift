import XCTest
@testable import RoxMovementAnalyzer

/// Covers the geometry primitives rowing analysis is built on, including regression cover for two
/// defects that made side-on lean unmeasurable.
final class RowingMeasurementsTests: XCTestCase {

    private func landmark(
        _ name: PoseLandmarkName, _ x: Double, _ y: Double, visibility: Double = 0.9
    ) -> PoseLandmark {
        PoseLandmark(name: name, x: x, y: y, z: 0, visibility: visibility, presence: visibility)
    }

    private func frame(_ landmarks: [PoseLandmark]) -> PoseFrame {
        PoseFrame(timestampInMilliseconds: 0, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks)
    }

    // MARK: - Signed lean

    func testSignedLeanDistinguishesForwardFromBackward() {
        let hip = landmark(.leftHip, 0.5, 0.6)
        let leaningRight = landmark(.leftShoulder, 0.6, 0.4)
        let leaningLeft = landmark(.leftShoulder, 0.4, 0.4)

        let right = PoseGeometry.signedAngleFromVertical(from: hip, to: leaningRight)
        let left = PoseGeometry.signedAngleFromVertical(from: hip, to: leaningLeft)

        XCTAssertNotNil(right)
        XCTAssertNotNil(left)
        XCTAssertGreaterThan(right!, 0, "a shoulder at greater x than the hip is a positive lean")
        XCTAssertLessThan(left!, 0, "the mirror image must not report the same sign")
        XCTAssertEqual(right!, -left!, accuracy: 0.001)
    }

    func testMagnitudeOnlyLeanIsUnchangedByTheSignedRewrite() {
        let hip = landmark(.leftHip, 0.5, 0.6)
        let leaningRight = landmark(.leftShoulder, 0.6, 0.4)
        let leaningLeft = landmark(.leftShoulder, 0.4, 0.4)

        XCTAssertEqual(
            PoseGeometry.angleFromVertical(from: hip, to: leaningRight)!,
            PoseGeometry.angleFromVertical(from: hip, to: leaningLeft)!,
            accuracy: 0.001,
            "angleFromVertical still discards direction, which is what its one caller expects"
        )
        XCTAssertEqual(PoseGeometry.angleFromVertical(from: hip, to: leaningRight)!, 26.565, accuracy: 0.01)
    }

    // MARK: - Visible-only centres

    func testVisibleCenterIgnoresTheOccludedFarJoint() {
        let sideOn = frame([
            landmark(.leftHip, 0.40, 0.60, visibility: 0.9),
            landmark(.rightHip, 0.90, 0.60, visibility: 0.1)
        ])

        let visible = sideOn.visibleCenter(.leftHip, .rightHip)
        XCTAssertEqual(visible?.x, 0.40, "only the tracked hip may contribute")

        let laundered = sideOn.midpoint(.leftHip, .rightHip)
        XCTAssertEqual(laundered?.x, 0.65, "midpoint still averages the estimated far joint in")
        XCTAssertTrue(
            laundered!.isVisible,
            "and reports the result as confident, which is why rowing cannot use it"
        )
    }

    func testVisibleCenterAveragesBothSidesWhenBothAreTracked() {
        let frontOn = frame([
            landmark(.leftShoulder, 0.40, 0.35),
            landmark(.rightShoulder, 0.60, 0.35)
        ])

        XCTAssertEqual(frontOn.visibleCenter(.leftShoulder, .rightShoulder)?.x, 0.50)
    }

    func testVisibleCenterIsNilWhenNeitherSideIsTracked() {
        let lost = frame([
            landmark(.leftHip, 0.40, 0.60, visibility: 0.1),
            landmark(.rightHip, 0.60, 0.60, visibility: 0.1)
        ])

        XCTAssertNil(lost.visibleCenter(.leftHip, .rightHip))
    }

    // MARK: - Facing

    func testFacingComesFromTheFeetBeingInFrontOfTheHips() {
        func seatedFrame(ankleX: Double, kneeX: Double) -> PoseFrame {
            frame([
                landmark(.leftHip, 0.50, 0.62),
                landmark(.leftKnee, kneeX, 0.55),
                landmark(.leftAnkle, ankleX, 0.72)
            ])
        }

        XCTAssertEqual(seatedFrame(ankleX: 0.70, kneeX: 0.66).facing, .right)
        XCTAssertEqual(seatedFrame(ankleX: 0.30, kneeX: 0.34).facing, .left)
    }

    func testFacingIsNilWhenTheLegsAreNotTracked() {
        let noLegs = frame([landmark(.leftHip, 0.50, 0.62)])
        XCTAssertNil(noLegs.facing)
    }

    func testForwardLeanIsPositiveTowardTheFlywheelWhicheverWayTheAthleteFaces() {
        let facingRight = frame([
            landmark(.leftHip, 0.50, 0.60),
            landmark(.leftShoulder, 0.60, 0.40)
        ])
        let facingLeft = frame([
            landmark(.leftHip, 0.50, 0.60),
            landmark(.leftShoulder, 0.40, 0.40)
        ])

        let right = facingRight.forwardTorsoLean(facing: .right)
        let left = facingLeft.forwardTorsoLean(facing: .left)

        XCTAssertNotNil(right)
        XCTAssertGreaterThan(right!, 0)
        XCTAssertEqual(right!, left!, accuracy: 0.001, "mirroring the athlete must not change the reading")
    }

    // MARK: - Scale reference

    func testScaleIsWithheldUntilEnoughSamples() {
        var scale = ScaleReference(minimumSamples: 3, outlierTolerance: 0.5)

        scale.observe(0.25)
        scale.observe(0.25)
        XCTAssertNil(scale.value, "scale-dependent faults must be suppressed, not guessed")

        scale.observe(0.25)
        XCTAssertEqual(scale.value!, 0.25, accuracy: 0.0001)
    }

    func testScaleRejectsCollapsedPoseSamples() {
        var scale = ScaleReference(minimumSamples: 3, outlierTolerance: 0.5)
        for _ in 0..<3 { scale.observe(0.25) }

        scale.observe(4.0)
        XCTAssertEqual(scale.value!, 0.25, accuracy: 0.0001, "a collapsed pose must not move the scale")
    }

    // MARK: - Viewpoint extraction

    func testViewpointClassificationIsUnchangedByTheThresholdExtraction() {
        func shouldered(spread: Double) -> PoseFrame {
            frame([
                landmark(.leftShoulder, 0.5 - spread / 2, 0.35),
                landmark(.rightShoulder, 0.5 + spread / 2, 0.35),
                landmark(.leftHip, 0.5, 0.60),
                landmark(.rightHip, 0.5, 0.60)
            ])
        }

        // Torso length is 0.25, so the ratio is spread / 0.25.
        XCTAssertEqual(shouldered(spread: 0.05).viewpoint(), .sideOn)
        XCTAssertEqual(shouldered(spread: 0.16).viewpoint(), .angled)
        XCTAssertEqual(shouldered(spread: 0.25).viewpoint(), .frontOn)

        XCTAssertEqual(
            shouldered(spread: 0.05).viewpoint(thresholds: WallBallThresholds.default.viewpoint),
            .sideOn,
            "the wall-ball thresholds must still classify identically after the extraction"
        )
    }
}
