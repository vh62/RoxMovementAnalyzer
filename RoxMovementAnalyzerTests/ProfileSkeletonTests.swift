import XCTest
@testable import RoxMovementAnalyzer

/// Covers drawing one side of the athlete when the camera is beside them, and the shared near-side
/// vote all three analysed stations now run.
final class ProfileSkeletonTests: XCTestCase {

    private func frame(_ landmarks: [PoseLandmark]) -> PoseFrame {
        PoseFrame(timestampInMilliseconds: 0, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks)
    }

    private func sagittalFrame(left: Double, right: Double) -> PoseFrame {
        frame(
            [PoseLandmarkName.leftHip, .leftKnee, .leftAnkle].map {
                PoseLandmark(name: $0, x: 0.5, y: 0.5, z: 0, visibility: left, presence: left)
            }
            + [PoseLandmarkName.rightHip, .rightKnee, .rightAnkle].map {
                PoseLandmark(name: $0, x: 0.5, y: 0.5, z: 0, visibility: right, presence: right)
            }
        )
    }

    // MARK: - The vote

    func testTheVoteLatchesTheBetterTrackedSide() {
        var vote = NearSideVote(voteFrames: 3)
        for _ in 0..<3 { vote.observe(sagittalFrame(left: 0.9, right: 0.1)) }

        XCTAssertEqual(vote.side, .left)
        XCTAssertEqual(vote.confidentSide, .left)
    }

    func testTheVoteFollowsWhicheverSideLeadsBeforeItSettles() {
        var vote = NearSideVote(voteFrames: 10)
        vote.observe(sagittalFrame(left: 0.1, right: 0.9))

        XCTAssertEqual(
            vote.side, .right,
            "measurement must not be stalled for half a second waiting for the vote"
        )
        XCTAssertNil(
            vote.confidentSide,
            "drawing waits, because a skeleton that switches sides mid-rep is worse than a late one"
        )
    }

    /// The pair that keeps measurement and drawing honest about how much evidence each needs.
    func testATieIsBrokenForMeasurementAndDeclinedForDrawing() {
        var vote = NearSideVote(voteFrames: 3)
        for _ in 0..<3 { vote.observe(sagittalFrame(left: 0.7, right: 0.7)) }

        XCTAssertNotNil(vote.side, "a measurement has to come from somewhere")
        XCTAssertNil(
            vote.confidentSide,
            "equal confidence is what a front-on athlete looks like: neither side occludes the other"
        )
    }

    func testAnUntrackedAthleteGivesNoSideAtAll() {
        XCTAssertNil(NearSideVote(voteFrames: 3).side)
    }

    // MARK: - The bones

    func testAProfileViewDrawsOneChainRatherThanTwelveBones() {
        let both = PoseOverlayGeometry.connections(for: nil)
        let one = PoseOverlayGeometry.connections(for: .left)

        XCTAssertEqual(both.count, 12)
        XCTAssertEqual(one.count, 5, "shoulder→elbow→wrist, shoulder→hip→knee→ankle")
    }

    func testNoFarSideJointSurvivesTheFilter() {
        let rightSide: Set<PoseLandmarkName> = [
            .rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle
        ]

        for (start, end) in PoseOverlayGeometry.connections(for: .left) {
            XCTAssertFalse(rightSide.contains(start), "\(start) is not on the drawn side")
            XCTAssertFalse(rightSide.contains(end), "\(end) is not on the drawn side")
        }
        XCTAssertTrue(PoseOverlayGeometry.landmarks(for: .left).isDisjoint(with: rightSide))
    }

    func testTheCrossBodyBonesAreGoneInProfile() {
        let one = PoseOverlayGeometry.connections(for: .left)

        XCTAssertFalse(
            one.contains { ($0.0 == .leftShoulder && $0.1 == .rightShoulder) || ($0.0 == .leftHip && $0.1 == .rightHip) },
            "side-on the cross-body bones collapse to a stub"
        )
    }

    // MARK: - Gating, per station

    func testBothErgsDrawOneSideInProfile() {
        var ski = SkiPullAnalyzer()
        for frame in SkiFixture.session() { ski.process(frame) }
        XCTAssertEqual(ski.profileSide, .left, "the ski fixture tracks its left side")

        var row = RowStrokeAnalyzer()
        for frame in RowingFixture.session() { row.process(frame) }
        XCTAssertEqual(row.profileSide, .left, "the rowing fixture tracks its left side")
    }

    func testAFrontOnCameraKeepsBothSidesEvenThoughASideIsAvailable() {
        var ski = SkiPullAnalyzer()
        for frame in SkiFixture.session(shoulderSpread: 0.22) { ski.process(frame) }

        XCTAssertNil(
            ski.profileSide,
            "the gate is the viewpoint, not whether a vote happens to have an answer"
        )
    }

    func testTheTimelineCarriesTheSameAnswerAsTheAnalyzer() {
        var ski = SkiPullAnalyzer()
        let frames = SkiFixture.session()
        for frame in frames { ski.process(frame) }

        let timeline = SessionTimeline(frames: frames, station: .skiErg)
        XCTAssertEqual(timeline.profileSide, ski.profileSide)
    }

    func testAStationWithNoSideVoteDrawsBothSides() {
        let timeline = SessionTimeline(frames: SkiFixture.stillFrames(), station: .burpeeBroadJumps)
        XCTAssertNil(timeline.profileSide, "burpees have no vote yet, so nothing is hidden")
    }

    /// Wall balls now runs the vote too, so it gets both halves: it picks the tracked side when one
    /// side is genuinely better tracked, and withholds when neither is.
    ///
    /// Frames are built here rather than borrowed from `WallBallRepAnalyzerTests`, whose fixture makes
    /// every landmark equally visible — `RowingFixture`'s doc calls that out as why it never caught the
    /// `midpoint` defect, and it is exactly the symmetry that cannot exercise a choice.
    func testWallBallsPicksTheTrackedSideAndWithholdsOnATie() {
        func profileFrame(near: Double, far: Double) -> PoseFrame {
            var landmarks: [PoseLandmark] = []
            func add(_ name: PoseLandmarkName, _ x: Double, _ y: Double, _ visibility: Double) {
                landmarks.append(
                    PoseLandmark(name: name, x: x, y: y, z: 0, visibility: visibility, presence: visibility)
                )
            }
            // A narrow apparent shoulder spread against a 0.25 torso is what reads as side-on.
            add(.leftShoulder, 0.48, 0.35, 0.9)
            add(.rightShoulder, 0.52, 0.35, 0.9)
            add(.leftHip, 0.5, 0.60, near)
            add(.rightHip, 0.5, 0.60, far)
            add(.leftKnee, 0.5, 0.75, near)
            add(.rightKnee, 0.5, 0.75, far)
            add(.leftAnkle, 0.5, 0.95, near)
            add(.rightAnkle, 0.5, 0.95, far)
            return PoseFrame(timestampInMilliseconds: 0, sourceAspectRatio: 9.0 / 16.0, landmarks: landmarks)
        }

        var tracked = WallBallRepAnalyzer()
        for _ in 0..<20 { tracked.process(profileFrame(near: 0.9, far: 0.1)) }
        XCTAssertEqual(tracked.profileSide, .left)

        var symmetric = WallBallRepAnalyzer()
        for _ in 0..<20 { symmetric.process(profileFrame(near: 0.9, far: 0.9)) }
        XCTAssertNil(
            symmetric.profileSide,
            "equal confidence is what a front-on athlete looks like, so nothing should be hidden"
        )
    }
}
