import XCTest
@testable import RoxMovementAnalyzer

/// Covers the pure logic behind session replay: rep counting, and mapping captured pose frames
/// onto video playback time.
final class SessionTimelineTests: XCTestCase {

    // MARK: - Fixtures

    /// A frame with hips and knees at the given normalized heights (y increases downward).
    private func makeFrame(ms: Int, hipY: Double, kneeY: Double, visible: Bool = true) -> PoseFrame {
        let confidence: Double = visible ? 0.9 : 0.1
        let landmarks = PoseLandmarkName.allCases.map { name -> PoseLandmark in
            let y: Double
            switch name {
            case .leftHip, .rightHip: y = hipY
            case .leftKnee, .rightKnee: y = kneeY
            case .leftAnkle, .rightAnkle: y = kneeY + 0.2
            case .leftShoulder, .rightShoulder: y = hipY - 0.25
            default: y = hipY - 0.1
            }
            return PoseLandmark(
                name: name, x: 0.5, y: y, z: 0, visibility: confidence, presence: confidence
            )
        }
        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    /// One squat cycle: standing → down to `bottomDelta` (hipY - kneeY) → standing.
    private func squatCycle(startMs: Int, bottomDelta: Double, step: Int = 33) -> [PoseFrame] {
        let kneeY = 0.6
        let deltas: [Double] = [-0.20, -0.10, -0.03, bottomDelta, -0.03, -0.10, -0.20]
        return deltas.enumerated().map { index, delta in
            makeFrame(ms: startMs + index * step, hipY: kneeY + delta, kneeY: kneeY)
        }
    }

    /// Three reps at legal depth followed by two deliberately shallow ones.
    private func mixedDepthSession() -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var t = 0
        for _ in 0..<3 { frames += squatCycle(startMs: t, bottomDelta: 0.05); t += 300 }
        for _ in 0..<2 { frames += squatCycle(startMs: t, bottomDelta: -0.04); t += 300 }
        return frames
    }

    // MARK: - WallBallRepCounter

    func testCountsOnlyRepsReachingLegalDepth() {
        let result = WallBallRepCounter().evaluate(frames: mixedDepthSession())

        XCTAssertEqual(result.validReps, 3, "only the hip-below-knee reps should count")
        XCTAssertEqual(result.attempts, 5, "every descent is an attempt")
        XCTAssertEqual(result.depthAccuracy, 0.6, accuracy: 0.001)
    }

    func testHoveringAtTheBottomCountsASingleRep() {
        let frames = [
            makeFrame(ms: 0, hipY: 0.40, kneeY: 0.6),
            makeFrame(ms: 33, hipY: 0.56, kneeY: 0.6),
            makeFrame(ms: 66, hipY: 0.62, kneeY: 0.6),
            makeFrame(ms: 99, hipY: 0.63, kneeY: 0.6),
            makeFrame(ms: 132, hipY: 0.61, kneeY: 0.6),
            makeFrame(ms: 165, hipY: 0.40, kneeY: 0.6)
        ]

        XCTAssertEqual(WallBallRepCounter().evaluate(frames: frames).validReps, 1)
    }

    func testUntrackedJointsDoNotRegisterMovement() {
        let frames = squatCycle(startMs: 0, bottomDelta: 0.05).map { frame in
            PoseFrame(
                timestampInMilliseconds: frame.timestampInMilliseconds,
                sourceAspectRatio: frame.sourceAspectRatio,
                landmarks: frame.landmarks.map {
                    PoseLandmark(name: $0.name, x: $0.x, y: $0.y, z: $0.z, visibility: 0.1, presence: 0.1)
                }
            )
        }

        XCTAssertEqual(WallBallRepCounter().evaluate(frames: frames).validReps, 0)
    }

    // MARK: - SessionTimeline

    func testTimelineIsAnchoredOnItsFirstFrame() {
        // Capture-clock timestamps share no origin with the movie timeline, so the timeline must
        // normalize them rather than assume they start at zero.
        let base = mixedDepthSession()
        let offset = base.map {
            PoseFrame(
                timestampInMilliseconds: $0.timestampInMilliseconds + 987_654,
                sourceAspectRatio: $0.sourceAspectRatio,
                landmarks: $0.landmarks
            )
        }

        let baseTimeline = SessionTimeline(frames: base, station: .wallBalls)
        let offsetTimeline = SessionTimeline(frames: offset, station: .wallBalls)

        XCTAssertEqual(offsetTimeline.entries.first?.seconds, 0)
        XCTAssertEqual(offsetTimeline.duration, baseTimeline.duration, accuracy: 0.0001)
    }

    func testFrameLookupResolvesToNearestPrecedingFrame() {
        let timeline = SessionTimeline(frames: mixedDepthSession(), station: .wallBalls)
        let second = timeline.entries[1].seconds

        XCTAssertNil(timeline.frame(at: -1), "nothing before the session starts")
        XCTAssertEqual(timeline.entry(at: second)?.seconds, second)
        XCTAssertNotNil(timeline.frame(at: second + 0.001))
    }

    func testFrameIsHiddenOnceItGoesStale() {
        let timeline = SessionTimeline(frames: mixedDepthSession(), station: .wallBalls)

        XCTAssertNotNil(
            timeline.frame(at: timeline.duration + 0.1),
            "a frame stays valid briefly after its timestamp"
        )
        XCTAssertNil(
            timeline.frame(at: timeline.duration + 5),
            "a tracking dropout should hide the overlay, not freeze it"
        )
    }

    func testRunningRepCountNeverDecreases() {
        let timeline = SessionTimeline(frames: mixedDepthSession(), station: .wallBalls)

        var previous = 0
        for step in stride(from: 0.0, through: timeline.duration, by: 0.02) {
            let count = timeline.validReps(at: step)
            XCTAssertGreaterThanOrEqual(count, previous, "rep count went backwards at \(step)s")
            previous = count
        }

        XCTAssertEqual(timeline.validReps(at: timeline.duration), 3)
        XCTAssertEqual(timeline.totalValidReps, 3)
    }

    func testRepCalloutFadesAfterTheRep() throws {
        let timeline = SessionTimeline(frames: mixedDepthSession(), station: .wallBalls)
        let repMoment = try XCTUnwrap(
            timeline.entries.first(where: { $0.lastRepCountedAt != nil })?.lastRepCountedAt
        )

        XCTAssertEqual(timeline.entry(at: repMoment)?.isCelebratingRep(at: repMoment), true)
        XCTAssertNotEqual(
            timeline.entry(at: repMoment + 5)?.isCelebratingRep(at: repMoment + 5), true
        )
    }

    func testEmptyTimelineIsSafe() {
        let timeline = SessionTimeline(frames: [], station: .wallBalls)

        XCTAssertTrue(timeline.isEmpty)
        XCTAssertEqual(timeline.duration, 0)
        XCTAssertNil(timeline.frame(at: 0))
        XCTAssertEqual(timeline.validReps(at: 3), 0)
    }

    func testNonWallBallStationsDoNotCountReps() {
        let timeline = SessionTimeline(frames: mixedDepthSession(), station: .running)

        XCTAssertEqual(timeline.totalValidReps, 0)
        XCTAssertNotNil(timeline.frame(at: 0.05), "frames are still replayable")
    }

    // MARK: - PoseOverlayGeometry

    func testDepthGuideReportsDepthAndPercentBelowParallel() throws {
        let deep = try XCTUnwrap(
            PoseOverlayGeometry.depthGuide(for: makeFrame(ms: 0, hipY: 0.65, kneeY: 0.6))
        )
        XCTAssertTrue(deep.hasReachedDepth)
        XCTAssertEqual(deep.percentBelowParallel, 5.0, accuracy: 0.001)

        let shallow = try XCTUnwrap(
            PoseOverlayGeometry.depthGuide(for: makeFrame(ms: 0, hipY: 0.55, kneeY: 0.6))
        )
        XCTAssertFalse(shallow.hasReachedDepth)
    }

    func testAspectFillMappingPutsTheCentreAtTheCentre() {
        let point = PoseOverlayGeometry.point(
            forNormalizedX: 0.5,
            y: 0.5,
            in: CGSize(width: 400, height: 800),
            sourceAspectRatio: 9.0 / 16.0
        )

        XCTAssertEqual(point.x, 200, accuracy: 0.001)
        XCTAssertEqual(point.y, 400, accuracy: 0.001)
    }
}
