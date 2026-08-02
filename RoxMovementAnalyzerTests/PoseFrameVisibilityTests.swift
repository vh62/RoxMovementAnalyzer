import XCTest
@testable import RoxMovementAnalyzer

/// Covers the full-body gate that decides whether the pose overlay is drawn at all.
///
/// Regression cover for a bug where the gate demanded every joint on *both* sides. Filmed from
/// the side — the angle the app actually recommends, since catch distance can only be measured
/// there — the far limb is hidden behind the near one and comes back at low confidence, so the
/// gate could never pass. That silently suppressed the live skeleton, the replay overlay and the
/// burned-in export, and drove the scorecard's coverage metric to zero.
final class PoseFrameVisibilityTests: XCTestCase {

    /// A frame as MediaPipe reports it side-on: near-side joints tracked, far side occluded.
    private func sideOnFrame(
        ms: Int = 0,
        nearSideTracked: Bool = true,
        ankleTracked: Bool = true
    ) -> PoseFrame {
        var landmarks: [PoseLandmark] = []

        func add(_ name: PoseLandmarkName, y: Double, visibility: Double) {
            landmarks.append(
                PoseLandmark(name: name, x: 0.5, y: y, z: 0,
                             visibility: visibility, presence: visibility)
            )
        }

        let near = nearSideTracked ? 0.9 : 0.1
        let occluded = 0.1

        add(.leftShoulder, y: 0.35, visibility: near)
        add(.rightShoulder, y: 0.35, visibility: occluded)
        add(.leftHip, y: 0.55, visibility: near)
        add(.rightHip, y: 0.55, visibility: occluded)
        add(.leftKnee, y: 0.70, visibility: near)
        add(.rightKnee, y: 0.70, visibility: occluded)
        add(.leftAnkle, y: 0.90, visibility: ankleTracked ? near : occluded)
        add(.rightAnkle, y: 0.90, visibility: occluded)

        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    func testSideOnFrameCountsAsFullBody() {
        XCTAssertTrue(
            sideOnFrame().hasFullBody,
            "the far limb being occluded must not suppress the whole skeleton"
        )
    }

    func testRegionUntrackedOnBothSidesStillFailsTheGate() {
        XCTAssertFalse(
            sideOnFrame(ankleTracked: false).hasFullBody,
            "if neither ankle is tracked the athlete's feet really are out of frame"
        )
    }

    func testNothingTrackedFailsTheGate() {
        XCTAssertFalse(sideOnFrame(nearSideTracked: false).hasFullBody)
    }

    func testEitherVisibleNeedsOnlyOneSide() {
        let frame = sideOnFrame()

        XCTAssertTrue(frame.isEitherVisible(.leftKnee, .rightKnee), "near knee is enough")
        XCTAssertFalse(
            frame.isEitherVisible(.rightKnee, .rightAnkle),
            "two occluded joints are not"
        )
    }
}
