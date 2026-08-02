import XCTest
@testable import RoxMovementAnalyzer

/// Covers rep segmentation and the movement-inefficiency detection built on top of it.
///
/// The synthetic athlete models the ball being carried at chest height (moving with the body) and
/// then driven overhead. That detail matters: with the ball pinned at a fixed height instead, the
/// shoulders dropping through the squat read as the hands rising, and the descent gets mistaken
/// for an arm drive.
final class WallBallRepAnalyzerTests: XCTestCase {

    private let fps = 30
    private var step: Int { 1000 / fps }

    // MARK: - Fixtures

    private func makeFrame(
        ms: Int,
        hipY: Double,
        kneeY: Double,
        wristY: Double,
        wristX: Double = 0.5,
        shoulderSpread: Double = 0.06,
        wristsVisible: Bool = true
    ) -> PoseFrame {
        let shoulderY = hipY - 0.25
        let ankleY = kneeY + 0.22
        var landmarks: [PoseLandmark] = []

        func add(_ name: PoseLandmarkName, _ x: Double, _ y: Double, visible: Bool = true) {
            landmarks.append(
                PoseLandmark(name: name, x: x, y: y, z: 0,
                             visibility: visible ? 0.9 : 0.1, presence: visible ? 0.9 : 0.1)
            )
        }

        add(.leftShoulder, 0.5 - shoulderSpread, shoulderY)
        add(.rightShoulder, 0.5 + shoulderSpread, shoulderY)
        add(.leftHip, 0.5 - shoulderSpread * 0.8, hipY)
        add(.rightHip, 0.5 + shoulderSpread * 0.8, hipY)
        add(.leftKnee, 0.5 - shoulderSpread * 0.8, kneeY)
        add(.rightKnee, 0.5 + shoulderSpread * 0.8, kneeY)
        add(.leftAnkle, 0.5 - shoulderSpread * 0.8, ankleY)
        add(.rightAnkle, 0.5 + shoulderSpread * 0.8, ankleY)
        add(.leftWrist, wristX, wristY, visible: wristsVisible)
        add(.rightWrist, wristX, wristY, visible: wristsVisible)
        add(.leftElbow, wristX, (shoulderY + wristY) / 2)
        add(.rightElbow, wristX, (shoulderY + wristY) / 2)

        return PoseFrame(
            timestampInMilliseconds: ms, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks
        )
    }

    /// One rep: descend → bottom → stand → (optional pause) → throw overhead → catch at `catchX`.
    /// `armLeadFrames` negative starts the arms before the legs finish; `pauseFrames` holds at full
    /// extension before throwing.
    private func rep(
        startMs: Int,
        bottomDelta: Double = 0.05,
        armLeadFrames: Int = 0,
        pauseFrames: Int = 0,
        catchX: Double = 0.5,
        shoulderSpread: Double = 0.06,
        wristsVisible: Bool = true
    ) -> (frames: [PoseFrame], endMs: Int) {
        var frames: [PoseFrame] = []
        var t = startMs
        let kneeY = 0.60
        let standHipY = kneeY - 0.20
        let bottomHipY = kneeY + bottomDelta
        let torso = 0.25
        let chestCarry = 0.10

        func push(_ hipY: Double, armOffset: Double, wristX: Double = 0.5) {
            let shoulderY = hipY - torso
            frames.append(
                makeFrame(ms: t, hipY: hipY, kneeY: kneeY, wristY: shoulderY + armOffset,
                          wristX: wristX, shoulderSpread: shoulderSpread,
                          wristsVisible: wristsVisible)
            )
            t += step
        }

        let descentFrames = 6
        for i in 0...descentFrames {
            let f = Double(i) / Double(descentFrames)
            push(standHipY + (bottomHipY - standHipY) * f, armOffset: chestCarry)
        }
        push(bottomHipY, armOffset: chestCarry)

        let ascentFrames = 8
        let armStartFrame = 7 + armLeadFrames
        var armOffset = chestCarry

        for i in 1...ascentFrames {
            let f = Double(i) / Double(ascentFrames)
            let hipY = bottomHipY + (standHipY - bottomHipY) * f
            if i >= armStartFrame { armOffset -= 0.06 }
            push(hipY, armOffset: armOffset)
        }

        for _ in 0..<pauseFrames { push(standHipY, armOffset: chestCarry) }
        while armOffset > -0.14 { armOffset -= 0.06; push(standHipY, armOffset: armOffset) }
        while armOffset < chestCarry {
            armOffset += 0.07
            push(standHipY, armOffset: min(armOffset, chestCarry))
        }
        for _ in 0..<5 { push(standHipY, armOffset: chestCarry, wristX: catchX) }

        return (frames, t)
    }

    private func session(reps count: Int) -> [PoseFrame] {
        var frames: [PoseFrame] = []
        var t = 0
        for _ in 0..<count {
            let r = rep(startMs: t)
            frames += r.frames
            t = r.endMs + 200
        }
        return frames
    }

    // MARK: - Segmentation

    func testSegmentsEveryRepAndItsPhases() {
        let reps = WallBallRepAnalyzer.analyze(frames: session(reps: 3))

        XCTAssertEqual(reps.count, 3)
        XCTAssertTrue(reps.allSatisfy(\.reachedDepth))
        XCTAssertTrue(reps.allSatisfy { $0.legExtendedSeconds != nil }, "leg extension")
        XCTAssertTrue(reps.allSatisfy { $0.armDriveStartSeconds != nil }, "arm drive onset")
        XCTAssertTrue(reps.allSatisfy { $0.releaseSeconds != nil }, "release peak")
        XCTAssertTrue(reps.allSatisfy { $0.catchSeconds != nil }, "catch")
    }

    /// The counter is now a wrapper over the analyzer, so counting must be unchanged.
    func testCounterStillAgreesWithTheAnalyzer() {
        let counted = WallBallRepCounter().evaluate(frames: session(reps: 3))
        XCTAssertEqual(counted.validReps, 3)
        XCTAssertEqual(counted.attempts, 3)

        var mixedFrames: [PoseFrame] = []
        var t = 0
        for _ in 0..<2 { let r = rep(startMs: t, bottomDelta: 0.05); mixedFrames += r.frames; t = r.endMs + 200 }
        for _ in 0..<3 { let r = rep(startMs: t, bottomDelta: -0.04); mixedFrames += r.frames; t = r.endMs + 200 }

        let mixed = WallBallRepCounter().evaluate(frames: mixedFrames)
        XCTAssertEqual(mixed.validReps, 2, "shallow reps are attempts, not valid reps")
        XCTAssertEqual(mixed.attempts, 5)
    }

    // MARK: - Release timing

    func testCleanRepIsNotFlagged() throws {
        let rep = try XCTUnwrap(WallBallRepAnalyzer.analyze(frames: rep(startMs: 0).frames).first)

        XCTAssertFalse(rep.hasFault(.earlyRelease))
        XCTAssertFalse(rep.hasFault(.lateRelease))
        XCTAssertNotNil(rep.releaseOffset)
    }

    func testArmsBeforeLegsIsFlaggedAsEarlyRelease() throws {
        let frames = rep(startMs: 0, armLeadFrames: -6).frames
        let rep = try XCTUnwrap(WallBallRepAnalyzer.analyze(frames: frames).first)

        XCTAssertTrue(rep.hasFault(.earlyRelease))
        XCTAssertFalse(rep.hasFault(.lateRelease))
        XCTAssertLessThan(try XCTUnwrap(rep.releaseOffset), 0)
    }

    func testPauseAtFullExtensionIsFlaggedAsLateRelease() throws {
        let frames = rep(startMs: 0, pauseFrames: 8).frames
        let rep = try XCTUnwrap(WallBallRepAnalyzer.analyze(frames: frames).first)

        XCTAssertTrue(rep.hasFault(.lateRelease))
        XCTAssertFalse(rep.hasFault(.earlyRelease))
        XCTAssertGreaterThan(try XCTUnwrap(rep.releaseOffset), 0)
    }

    // MARK: - Catch position

    func testCatchCloseToTheBodyIsNotFlagged() throws {
        let rep = try XCTUnwrap(
            WallBallRepAnalyzer.analyze(frames: rep(startMs: 0, catchX: 0.5).frames).first
        )

        XCTAssertNotNil(rep.catchSeconds)
        XCTAssertFalse(rep.hasFault(.catchTooFarForward))
    }

    func testCatchFarInFrontIsFlagged() throws {
        let rep = try XCTUnwrap(
            WallBallRepAnalyzer.analyze(frames: rep(startMs: 0, catchX: 0.68).frames).first
        )

        XCTAssertEqual(rep.viewpoint, .sideOn)
        XCTAssertTrue(rep.hasFault(.catchTooFarForward))
    }

    /// Horizontal reach cannot be measured facing the camera, so it must be suppressed rather than
    /// reported as a confident wrong number.
    func testReachFaultIsSuppressedFrontOn() throws {
        let frames = rep(startMs: 0, catchX: 0.68, shoulderSpread: 0.13).frames
        let rep = try XCTUnwrap(WallBallRepAnalyzer.analyze(frames: frames).first)

        XCTAssertEqual(rep.viewpoint, .frontOn)
        XCTAssertFalse(rep.hasFault(.catchTooFarForward))
    }

    // MARK: - Degraded tracking

    func testNoReleaseFaultsInventedWhenTheHandsLeaveFrame() throws {
        let frames = rep(startMs: 0, wristsVisible: false).frames
        let rep = try XCTUnwrap(WallBallRepAnalyzer.analyze(frames: frames).first)

        XCTAssertFalse(rep.handsTracked)
        XCTAssertNil(rep.releaseSeconds)
        XCTAssertTrue(rep.faults.isEmpty)
    }

    // MARK: - Timeline integration

    func testTimelineExposesFaultsForPlaybackCallouts() throws {
        var frames: [PoseFrame] = []
        var t = 0
        for _ in 0..<2 { let r = rep(startMs: t); frames += r.frames; t = r.endMs + 200 }
        let faulted = rep(startMs: t, armLeadFrames: -6)
        frames += faulted.frames

        let timeline = SessionTimeline(frames: frames, station: .wallBalls)
        let faultedRep = try XCTUnwrap(timeline.faultedReps.first)

        XCTAssertEqual(timeline.reps.count, 3)
        XCTAssertNotNil(timeline.activeFault(at: faultedRep.endSeconds + 0.2), "callout is held")
        XCTAssertNil(
            timeline.activeFault(at: faultedRep.endSeconds + 5),
            "callout fades rather than sticking for the rest of the video"
        )
    }

    func testNonWallBallStationsProduceNoReps() {
        let timeline = SessionTimeline(frames: session(reps: 2), station: .running)
        XCTAssertTrue(timeline.reps.isEmpty)
    }
}
