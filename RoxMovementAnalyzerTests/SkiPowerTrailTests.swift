import CoreGraphics
import XCTest
@testable import RoxMovementAnalyzer

/// Covers the hand path the replay overlay draws — the force curve laid onto the athlete's own range
/// of motion — and the seams that carry it from the analyzer to the two renderers.
final class SkiPowerTrailTests: XCTestCase {

    private func measured(_ frames: [PoseFrame]) -> [SkiPull] {
        SkiFixture.measuredPulls(frames)
    }

    // MARK: - The trail itself

    func testTheTrailFollowsTheDriveAndIsNormalisedToItsOwnPeak() {
        for pull in measured(SkiFixture.session()) {
            XCTAssertGreaterThan(pull.powerTrail.count, 5, "a drive is more than a handful of points")
            XCTAssertTrue(
                pull.powerTrail.allSatisfy { (0...1).contains($0.intensity) },
                "intensity is a share of this pull's own peak, so it cannot leave 0...1"
            )
            XCTAssertEqual(
                pull.powerTrail.map(\.intensity).max()!, 1, accuracy: 0.0001,
                "the peak defines the scale, so exactly one point must sit at the top of it"
            )
        }
    }

    /// The trail and `peakAtDriveFraction` now describe the same peak twice. They have to agree, or the
    /// overlay would highlight one part of the range while the readout named another.
    func testTheBrightestPointSitsWhereTheReadoutSaysThePeakIs() {
        for pull in measured(SkiFixture.session()) {
            let brightest = pull.powerTrail.firstIndex { $0.intensity >= 1 }!
            let position = Double(brightest) / Double(pull.powerTrail.count - 1)

            XCTAssertEqual(
                position, pull.peakAtDriveFraction!, accuracy: 0.15,
                "the bright band must land where the scalar says the power did"
            )
        }
    }

    func testTheTrailLandsOnTheHandsRatherThanNearThem() {
        let frames = SkiFixture.session()
        let pull = measured(frames)[0]

        // Every point must coincide with a wrist centre from some frame in the session: the trail is
        // drawn in the same normalized space as the landmarks, and off-by-a-scale-factor is the defect
        // this catches.
        let wrists = frames.compactMap { $0.visibleCenter(.leftWrist, .rightWrist) }
        for sample in pull.powerTrail {
            XCTAssertTrue(
                wrists.contains { abs($0.x - sample.x) < 0.0001 && abs($0.y - sample.y) < 0.0001 },
                "trail point (\(sample.x), \(sample.y)) is not a tracked wrist position"
            )
        }
    }

    // MARK: - Suppression

    /// The trail and the verdict must appear and vanish together, or the replay would show a force
    /// curve the scorecard declined to measure.
    func testTheTrailIsEmptyExactlyWhenTheForceCurveIsUnmeasurable() {
        let lost = SkiPullAnalyzer.analyze(frames: SkiFixture.session(wristsVisible: false))
        XCTAssertFalse(lost.isEmpty)
        for pull in lost {
            XCTAssertNil(pull.peakHandSpeed)
            XCTAssertTrue(pull.powerTrail.isEmpty, "no verdict means nothing to draw")
        }

        // The opening pull is the scale warm-up, where the hand measurements are withheld by design.
        let warmUp = SkiPullAnalyzer.analyze(frames: SkiFixture.session())
        XCTAssertNil(warmUp.first?.peakHandSpeed)
        XCTAssertTrue(warmUp.first!.powerTrail.isEmpty)
        XCTAssertFalse(warmUp.last!.powerTrail.isEmpty)
    }

    // MARK: - The timeline seam

    func testTheTimelineHandsOutTheTrailForThePullAtThePlayhead() {
        let timeline = SessionTimeline(frames: SkiFixture.session(), station: .skiErg)
        let pull = timeline.movements.last!

        let during = timeline.powerTrail(at: (pull.startSeconds + pull.endSeconds) / 2)
        XCTAssertFalse(during.isEmpty)

        XCTAssertTrue(
            timeline.powerTrail(at: -1).isEmpty,
            "before the first pull there is no hand path to draw"
        )
    }

    func testARowingSessionHasNoTrailToDraw() {
        let timeline = SessionTimeline(frames: RowingFixture.session(), station: .rowing)

        XCTAssertFalse(timeline.movements.isEmpty, "the rowing session must actually have strokes")
        XCTAssertTrue(
            timeline.powerTrail(at: timeline.duration / 2).isEmpty,
            "the force proxy is a SkiErg measurement; nothing else may inherit it by accident"
        )
    }

    // MARK: - Shared drawing rules

    func testSegmentsPairConsecutivePointsAndSpanTheTrail() {
        let trail = measured(SkiFixture.session())[0].powerTrail
        let segments = PoseOverlayGeometry.trailSegments(
            trail, in: CGSize(width: 390, height: 844), sourceAspectRatio: 9.0 / 16.0
        )

        XCTAssertEqual(segments.count, trail.count - 1)
        for (first, second) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(first.to.x, second.from.x, accuracy: 0.0001, "the path must be continuous")
            XCTAssertEqual(first.to.y, second.from.y, accuracy: 0.0001)
        }
    }

    func testASingleSampleDrawsNothing() {
        let one = [SkiPull.PowerSample(x: 0.5, y: 0.5, intensity: 1)]
        XCTAssertTrue(
            PoseOverlayGeometry.trailSegments(
                one, in: CGSize(width: 390, height: 844), sourceAspectRatio: 9.0 / 16.0
            ).isEmpty,
            "one point is not a path"
        )
    }

    /// Both renderers read the ramp from here, so this is what stops the replay and the exported video
    /// drawing the same pull two different ways.
    func testTheShadingRampIsMonotonicAndBounded() {
        let steps = stride(from: 0.0, through: 1.0, by: 0.1).map {
            PoseOverlayGeometry.trailShading(intensity: $0)
        }

        for (lower, higher) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThan(lower.width, higher.width)
            XCTAssertLessThan(lower.alpha, higher.alpha)
        }

        XCTAssertGreaterThan(steps.first!.alpha, 0, "an unloaded stretch stays faintly visible")
        XCTAssertLessThanOrEqual(steps.last!.alpha, 1)

        // Out-of-range input is clamped rather than extrapolated into an invalid colour.
        XCTAssertEqual(
            PoseOverlayGeometry.trailShading(intensity: 5).alpha,
            PoseOverlayGeometry.trailShading(intensity: 1).alpha
        )
    }
}
