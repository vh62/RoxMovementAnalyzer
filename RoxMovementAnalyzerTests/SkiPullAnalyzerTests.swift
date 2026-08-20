import XCTest
@testable import RoxMovementAnalyzer

/// Covers SkiErg pull segmentation and the technique faults built on top of it.
///
/// The synthetic skier lives in `SkiFixture`, which builds the athlete kinematically so the shoulder
/// sweep and elbow angles the analyzer measures emerge from the model rather than being written into it.
final class SkiPullAnalyzerTests: XCTestCase {

    private func measured(_ frames: [PoseFrame]) -> [SkiPull] {
        SkiFixture.measuredPulls(frames)
    }

    // MARK: - Segmentation

    func testCatchToCatchPullsYieldOneFewerThanTheCatches() {
        let pulls = SkiPullAnalyzer.analyze(frames: SkiFixture.session(cycles: 4))

        XCTAssertEqual(
            pulls.count, 3,
            "a pull is bounded by two catches, so N catches yield N−1 pulls — the trailing partial has "
                + "no recovery and cannot be measured"
        )
    }

    func testEveryPullHasItsPhases() {
        for pull in measured(SkiFixture.session()) {
            XCTAssertGreaterThan(pull.driveSeconds, 0)
            XCTAssertGreaterThan(pull.recoverySeconds, 0)
            XCTAssertNotNil(pull.peakHandSpeed)
            XCTAssertNotNil(pull.peakAtDriveFraction)
            XCTAssertEqual(pull.facing, .right)
            XCTAssertEqual(pull.viewpoint, .sideOn)
        }
    }

    func testPullRateMatchesTheSyntheticCadence() {
        let pull = measured(SkiFixture.session()).first
        XCTAssertNotNil(pull?.pullRateSPM)
        XCTAssertEqual(pull!.pullRateSPM!, 45, accuracy: 2)
    }

    func testCleanPullIsNotFlagged() {
        for pull in measured(SkiFixture.session()) {
            XCTAssertEqual(
                pull.faults, [],
                "the clean pull is load-bearing: every fault test is only meaningful against it"
            )
        }
    }

    func testFacingLeftGivesTheSameResultAsFacingRight() {
        let mirrored = measured(SkiFixture.session(mirrored: true))
        let normal = measured(SkiFixture.session())

        XCTAssertEqual(mirrored.count, normal.count)
        XCTAssertEqual(mirrored.first?.facing, .left)
        for (left, right) in zip(mirrored, normal) {
            XCTAssertEqual(left.faults, right.faults, "mirroring the athlete must change nothing")
        }
    }

    func testPauseAtTheTopDoesNotSplitThePull() {
        let held = SkiPullAnalyzer.analyze(frames: SkiFixture.session(catchHoldFrames: 6))

        XCTAssertEqual(
            held.count, 3,
            "the running maximum should sit at the catch until the athlete actually pulls, rather than "
                + "reading the pause as a pull of its own"
        )
    }

    func testStandingStillYieldsNoPulls() {
        XCTAssertTrue(SkiPullAnalyzer.analyze(frames: SkiFixture.stillFrames()).isEmpty)
    }

    func testShallowArmSweepIsNotAPull() {
        // Arms that never get overhead: the shoulder angle sweeps well under `minPullShoulderRange`.
        let shallow = SkiPullAnalyzer.analyze(frames: SkiFixture.session(catchArmAngle: 130))

        XCTAssertTrue(
            shallow.isEmpty,
            "a gesture that never reaches overhead is fidgeting with the handles, not a pull"
        )
    }

    func testTrackingGapDiscardsThePullItFallsIn() {
        let gapped = SkiPullAnalyzer.analyze(frames: SkiFixture.session(gapFramesAfterFirstPull: 15))
        let clean = SkiPullAnalyzer.analyze(frames: SkiFixture.session())

        XCTAssertLessThan(
            gapped.count, clean.count,
            "a dropout long enough to distort a phase must lose the pull rather than report inflated "
                + "timings for it"
        )
    }

    // MARK: - Hinge

    func testAnUprightPullIsFlaggedAsNoHipHinge() {
        // Barely any hinge and barely any knee bend: the pull came from the arms alone.
        for pull in measured(
            SkiFixture.session(finishLean: 20, finishHipBack: 0.04, finishHipDrop: 0.010)
        ) {
            XCTAssertTrue(pull.hasFault(.noHipHinge), "faults were \(pull.faults)")
            XCTAssertNil(
                pull.hingeToKneeRatio,
                "a pull that barely bends the knees is not a squat, whatever the ratio would say"
            )
        }
    }

    func testKneesDoingTheHingesWorkIsFlaggedAsSquatting() {
        for pull in measured(SkiFixture.session(finishLean: 20)) {
            XCTAssertTrue(pull.hasFault(.squattingNotHinging), "faults were \(pull.faults)")
            XCTAssertLessThan(pull.hingeToKneeRatio!, 1)
        }
    }

    func testTheMissingHingeIsReportedOnceRatherThanTwice() {
        let sessions = [
            SkiFixture.session(finishLean: 20),
            SkiFixture.session(finishLean: 20, finishHipBack: 0.04, finishHipDrop: 0.010)
        ]

        for pull in sessions.flatMap({ measured($0) }) {
            XCTAssertFalse(
                pull.hasFault(.noHipHinge) && pull.hasFault(.squattingNotHinging),
                "both cases are the same missing hinge; the ratio only chooses which cue to give"
            )
        }
    }

    // MARK: - Force curve

    /// The load-bearing assertion for the whole force-curve family: a body-driven pull front-loads.
    func testACleanPullFrontLoadsItsPower() {
        for pull in measured(SkiFixture.session()) {
            XCTAssertLessThan(
                pull.peakAtDriveFraction!, SkiThresholds.default.maxPeakDriveFraction,
                "the compression should put the peak in the first half, which is what makes the other "
                    + "force-curve checks mean anything"
            )
            XCTAssertNil(pull.midDriveDip, "a single push has no second peak to dip between")
        }
    }

    func testPowerPeakingLateIsFlagged() {
        for pull in measured(SkiFixture.session(drivePeakFraction: 0.85)) {
            XCTAssertTrue(pull.hasFault(.backLoadedDrive), "faults were \(pull.faults)")
            XCTAssertGreaterThan(
                pull.peakAtDriveFraction!, SkiThresholds.default.maxPeakDriveFraction
            )
        }
    }

    func testADriveInTwoEffortsIsFlaggedAsDisconnected() {
        for pull in measured(SkiFixture.session(armSurge: 1.0)) {
            XCTAssertTrue(pull.hasFault(.disconnectedDrive), "faults were \(pull.faults)")
            XCTAssertLessThan(pull.midDriveDip!, SkiThresholds.default.maxMidDriveDip)
        }
    }

    /// Top-end load is computed and reported but never faulted, because on a single-peaked profile it
    /// is the peak position seen from the other end. This pins that down: a pull that drifts through
    /// the top shows a lower figure, and still raises nothing on its own.
    func testTopEndLoadIsReportedWithoutBeingFaulted() {
        let connected = measured(SkiFixture.session())
        let drifting = measured(SkiFixture.session(topDwell: 0.6))

        XCTAssertLessThan(
            drifting[0].catchConnection!, connected[0].catchConnection!,
            "the measurement has to move in the right direction to be worth showing at all"
        )
        XCTAssertEqual(
            drifting.flatMap(\.faults), [],
            "a drift at the top that never becomes a late peak is a shape, not a finding"
        )
    }

    /// The check that keeps the force proxy honest: it is a shape, not a force, so the same pull taken
    /// at a different cadence must still read as the same *shape*.
    ///
    /// The verdict is asserted, not the raw figure. `peakAtDriveFraction` is measured over the
    /// **detected** drive, and the detected catch sits a few degrees into the sweep — it is credited to
    /// the maximum of a smoothed signal, which needs `shoulderReversalHysteresis` to confirm, so a
    /// near-stationary top is trimmed off. How much gets trimmed depends on the cadence, which moves
    /// the number by more than a tolerance worth writing down (0.11 at 12 drive frames, 0.28 at 24)
    /// while leaving the verdict untouched at every cadence tried.
    func testTheForceCurveReadsTheShapeRatherThanTheSpeed() {
        for frames in [12, 16, 24] {
            let pulls = measured(
                SkiFixture.session(driveFrames: frames, recoveryFrames: frames * 3 / 2)
            )

            XCTAssertFalse(pulls.isEmpty, "\(frames) drive frames")
            XCTAssertLessThan(
                pulls[0].peakAtDriveFraction!, SkiThresholds.default.maxPeakDriveFraction,
                "a front-loaded pull must read as front-loaded at every cadence — \(frames) frames"
            )
        }

        let quick = measured(SkiFixture.session(driveFrames: 12, recoveryFrames: 18))
        let slow = measured(SkiFixture.session(driveFrames: 24, recoveryFrames: 36))
        XCTAssertGreaterThan(
            quick[0].peakHandSpeed!, slow[0].peakHandSpeed!,
            "the same shape pulled faster must still read as faster in absolute terms"
        )
    }

    // MARK: - Suppression

    /// The load-bearing test for the whole segmentation choice.
    func testLosingTheWristsStillCountsPullsAndDropsOnlyTheForceCurve() {
        let visible = SkiPullAnalyzer.analyze(frames: SkiFixture.session(drivePeakFraction: 0.85))
        let lost = SkiPullAnalyzer.analyze(
            frames: SkiFixture.session(drivePeakFraction: 0.85, wristsVisible: false)
        )

        XCTAssertEqual(
            lost.count, visible.count,
            "segmentation runs on the shoulder angle precisely so that an overhead reach leaving the "
                + "hands out of frame costs the force curve, not the whole station"
        )
        // Past the opening scale warm-up, where hand measurements are withheld by design.
        XCTAssertTrue(visible.dropFirst().allSatisfy { $0.hasFault(.backLoadedDrive) })

        for pull in lost {
            XCTAssertFalse(pull.handsTracked)
            XCTAssertNil(pull.peakHandSpeed)
            XCTAssertFalse(
                pull.hasFault(.backLoadedDrive) || pull.hasFault(.disconnectedDrive),
                "a measurement that could not be taken must not be reported as a fault"
            )
        }
    }

    /// The hinge half of the split: losing the hands must not cost the checks that never needed them.
    func testLosingTheWristsKeepsTheHingeChecks() {
        let pulls = SkiPullAnalyzer.analyze(
            frames: SkiFixture.session(finishLean: 20, wristsVisible: false)
        )

        XCTAssertFalse(pulls.isEmpty)
        XCTAssertTrue(pulls.dropFirst().allSatisfy { $0.hasFault(.squattingNotHinging) })
    }

    func testAFrontOnCameraSuppressesTheHingeFaults() {
        let pulls = measured(SkiFixture.session(finishLean: 20, shoulderSpread: 0.22))

        XCTAssertFalse(pulls.isEmpty)
        for pull in pulls {
            XCTAssertEqual(pull.viewpoint, .frontOn)
            XCTAssertFalse(
                pull.hasFault(.noHipHinge) || pull.hasFault(.squattingNotHinging),
                "front-on the torso hinges in depth rather than across the image, so every athlete "
                    + "would read as never hinging"
            )
        }
    }

    func testScaleDependentFaultsAreSuppressedOnTheFirstPull() {
        let pulls = SkiPullAnalyzer.analyze(frames: SkiFixture.session(drivePeakFraction: 0.85))

        XCTAssertNil(
            pulls.first?.peakHandSpeed,
            "the scale is withheld until it has enough samples, so the opening pull reports fewer "
                + "faults than a later identical one rather than measuring against a half-formed mean"
        )
        XCTAssertNotNil(pulls.last?.peakHandSpeed)
    }

    // MARK: - Facing

    func testFacingComesFromTheFaceAndTheToesRatherThanTheHands() {
        let frames = SkiFixture.session()

        // Fixed anatomy, so the vote is the same at the catch and at the finish — which is the point:
        // a wrist-based vote would reverse between them.
        XCTAssertEqual(frames[0].standingFacing, .right)
        XCTAssertEqual(frames[16].standingFacing, .right)
        XCTAssertEqual(SkiFixture.session(mirrored: true)[0].standingFacing, .left)
    }

    func testFacingIsNilWhenTheHeadAndFeetAreNotTracked() {
        let bare = PoseFrame(
            timestampInMilliseconds: 0,
            sourceAspectRatio: 9.0 / 16.0,
            landmarks: [
                PoseLandmark(name: .leftHip, x: 0.5, y: 0.6, z: 0, visibility: 0.9, presence: 0.9),
                PoseLandmark(name: .leftShoulder, x: 0.5, y: 0.35, z: 0, visibility: 0.9, presence: 0.9)
            ]
        )

        XCTAssertNil(bare.standingFacing)
    }
}
