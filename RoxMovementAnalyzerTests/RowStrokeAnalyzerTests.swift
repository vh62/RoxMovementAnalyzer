import XCTest
@testable import RoxMovementAnalyzer

/// Covers stroke segmentation and the technique faults built on top of it.
///
/// The synthetic rower lives in `RowingFixture`, which builds the athlete kinematically so the
/// angles the analyzer measures emerge from the model rather than being written into it.
final class RowStrokeAnalyzerTests: XCTestCase {

    private func measured(_ frames: [PoseFrame]) -> [RowStroke] {
        RowingFixture.measuredStrokes(frames)
    }

    // MARK: - Segmentation

    func testCatchToCatchStrokesYieldOneFewerThanTheCatches() {
        let strokes = RowStrokeAnalyzer.analyze(frames: RowingFixture.session(cycles: 4))

        XCTAssertEqual(
            strokes.count, 3,
            "a stroke is bounded by two catches, so N catches yield N−1 strokes — the trailing "
                + "partial has no recovery and cannot be measured"
        )
    }

    func testEveryStrokeHasItsPhases() {
        for stroke in measured(RowingFixture.session()) {
            XCTAssertGreaterThan(stroke.driveSeconds, 0)
            XCTAssertGreaterThan(stroke.recoverySeconds, 0)
            XCTAssertNotNil(stroke.legDriveDoneSeconds)
            XCTAssertNotNil(stroke.backOpenSeconds)
            XCTAssertNotNil(stroke.armBreakSeconds)
            XCTAssertEqual(stroke.facing, .right)
            XCTAssertEqual(stroke.viewpoint, .sideOn)
        }
    }

    func testStrokeRateMatchesTheSyntheticCadence() {
        let stroke = measured(RowingFixture.session()).first
        XCTAssertNotNil(stroke?.strokeRateSPM)
        XCTAssertEqual(stroke!.strokeRateSPM!, 30, accuracy: 1.5)
    }

    func testCleanStrokeIsNotFlagged() {
        for stroke in measured(RowingFixture.session()) {
            XCTAssertEqual(
                stroke.faults, [],
                "the clean stroke is load-bearing: every fault test is only meaningful against it"
            )
        }
    }

    func testFacingLeftGivesTheSameResultAsFacingRight() {
        let mirrored = measured(RowingFixture.session(mirrored: true))
        let normal = measured(RowingFixture.session())

        XCTAssertEqual(mirrored.count, normal.count)
        XCTAssertEqual(mirrored.first?.facing, .left)
        for (left, right) in zip(mirrored, normal) {
            XCTAssertEqual(left.faults, right.faults, "mirroring the athlete must change nothing")
            XCTAssertEqual(left.catchKneeAngle, right.catchKneeAngle, accuracy: 0.001)
            XCTAssertEqual(left.finishForwardLean!, right.finishForwardLean!, accuracy: 0.001)
            XCTAssertEqual(left.slideRatio!, right.slideRatio!, accuracy: 0.001)
        }
    }

    func testStillAthleteProducesNoStrokes() {
        XCTAssertEqual(RowStrokeAnalyzer.analyze(frames: RowingFixture.stillFrames()).count, 0)
    }

    func testTrackingGapDiscardsTheStrokeItFallsIn() {
        let withGap = RowStrokeAnalyzer.analyze(
            frames: RowingFixture.session(cycles: 4, gapFramesAfterFirstStroke: 20)
        )

        XCTAssertLessThan(
            withGap.count, 3,
            "a gap long enough to distort a phase must discard the stroke, not stretch it"
        )
        for stroke in withGap {
            XCTAssertFalse(
                stroke.hasFault(.rushingTheRecovery),
                "a dropout must never manufacture a rhythm fault"
            )
        }
    }

    func testPauseAtTheCatchDoesNotSplitAStroke() {
        let strokes = RowStrokeAnalyzer.analyze(
            frames: RowingFixture.session(cycles: 3, catchHoldFrames: 15)
        )

        XCTAssertEqual(strokes.count, 2, "holding at the catch is one stroke, not two")
        XCTAssertGreaterThan(strokes[1].recoverySeconds, strokes[1].driveSeconds)
    }

    func testAbsurdlySlowStrokeIsDropped() {
        let strokes = RowStrokeAnalyzer.analyze(
            frames: RowingFixture.session(cycles: 3, recoveryFrames: 150)
        )

        XCTAssertEqual(strokes.count, 0, "a rest between pieces is not a 10 spm stroke")
    }

    // MARK: - Sequence

    func testTorsoOpeningBeforeTheLegsFinishIsFlagged() {
        let stroke = measured(RowingFixture.session(backOpenAtDriveFraction: 0.15))[0]

        XCTAssertTrue(stroke.hasFault(.sequenceBackTooEarly))
        XCTAssertLessThan(stroke.backSwingOffset!, 0)
        XCTAssertFalse(stroke.hasFault(.sequenceArmsTooEarly), "only the back went early")
    }

    func testArmsBendingBeforeTheLegsFinishIsFlagged() {
        let stroke = measured(RowingFixture.session(armBreakAtDriveFraction: 0.20))[0]

        XCTAssertTrue(stroke.hasFault(.sequenceArmsTooEarly))
        XCTAssertLessThan(stroke.armBreakOffset!, 0)
        XCTAssertFalse(stroke.hasFault(.sequenceBackTooEarly), "only the arms went early")
    }

    func testBothSequenceErrorsCanBeReportedTogether() {
        let stroke = measured(
            RowingFixture.session(backOpenAtDriveFraction: 0.15, armBreakAtDriveFraction: 0.20)
        )[0]

        XCTAssertTrue(stroke.hasFault(.sequenceBackTooEarly))
        XCTAssertTrue(
            stroke.hasFault(.sequenceArmsTooEarly),
            "they co-occur constantly, which is why they are separate cases rather than one payload"
        )
    }

    func testArmSequenceIsSuppressedWhenTheWristsLeaveFrameButTheBackIsNot() {
        let stroke = measured(
            RowingFixture.session(
                backOpenAtDriveFraction: 0.15,
                armBreakAtDriveFraction: 0.20,
                wristsVisible: false
            )
        )[0]

        XCTAssertFalse(
            stroke.hasFault(.sequenceArmsTooEarly),
            "an elbow angle taken from a guessed wrist is not a measurement"
        )
        XCTAssertTrue(
            stroke.hasFault(.sequenceBackTooEarly),
            "losing the wrists must not suppress the half of the family that never needed them"
        )
    }

    // MARK: - Shooting the slide

    func testSeatRunningAwayFromTheHandleIsFlagged() {
        let stroke = measured(RowingFixture.session(slideSlipFraction: 0.35))[0]

        XCTAssertTrue(stroke.hasFault(.shootingTheSlide))
        XCTAssertLessThan(stroke.slideRatio!, RowingThresholds.default.minSlideRatio)
    }

    func testShootingTheSlideIsNotConfusedWithOpeningTheBackEarly() {
        let stroke = measured(RowingFixture.session(slideSlipFraction: 0.35))[0]

        XCTAssertFalse(
            stroke.hasFault(.sequenceBackTooEarly),
            "the hips sliding out rotates the torso further forward, not open — the two errors "
                + "move the lean in opposite directions"
        )
    }

    func testShootingTheSlideIsSuppressedFrontOn() {
        let stroke = measured(
            RowingFixture.session(slideSlipFraction: 0.35, shoulderSpread: 0.25)
        )[0]

        XCTAssertEqual(stroke.viewpoint, .frontOn)
        XCTAssertFalse(
            stroke.hasFault(.shootingTheSlide),
            "horizontal travel cannot be measured honestly from the front"
        )
    }

    func testShootingTheSlideIsSuppressedWhenTheWristsLeaveFrame() {
        let stroke = measured(
            RowingFixture.session(slideSlipFraction: 0.35, wristsVisible: false)
        )[0]

        XCTAssertFalse(stroke.hasFault(.shootingTheSlide))
        XCTAssertFalse(stroke.handsTracked)
    }

    // MARK: - Rhythm

    func testRushedRecoveryIsFlagged() {
        let stroke = measured(RowingFixture.session(recoveryFrames: 22))[0]

        XCTAssertTrue(stroke.hasFault(.rushingTheRecovery))
        XCTAssertLessThan(stroke.recoveryRatio!, RowingThresholds.default.minRecoveryRatio)
    }

    func testTwoToOneRecoveryIsNotFlagged() {
        for stroke in measured(RowingFixture.session()) {
            XCTAssertGreaterThan(stroke.recoveryRatio!, RowingThresholds.default.minRecoveryRatio)
            XCTAssertFalse(stroke.hasFault(.rushingTheRecovery))
        }
    }

    // MARK: - Range of motion

    func testShallowCatchIsFlagged() {
        let stroke = measured(RowingFixture.session(catchSeatBack: 0.22))[0]

        XCTAssertTrue(stroke.hasFault(.incompleteCatch))
        XCTAssertGreaterThan(stroke.catchKneeAngle, RowingThresholds.default.maxCatchKneeAngle)
    }

    func testNoLaybackIsFlagged() {
        let stroke = measured(RowingFixture.session(finishLean: 5))[0]

        XCTAssertTrue(stroke.hasFault(.noLayback))
        XCTAssertGreaterThan(stroke.finishForwardLean!, 0)
    }

    func testHandleNotDrawnInIsFlagged() {
        let stroke = measured(RowingFixture.session(finishArmReach: 0.22))[0]

        XCTAssertTrue(stroke.hasFault(.shortFinish))
        XCTAssertGreaterThan(
            stroke.finishHandleAheadOfHips!,
            RowingThresholds.default.maxFinishHandleDistance
        )
    }

    func testFullRangeStrokeRaisesNoRangeFaults() {
        for stroke in measured(RowingFixture.session()) {
            XCTAssertFalse(stroke.hasFault(.incompleteCatch))
            XCTAssertFalse(stroke.hasFault(.noLayback))
            XCTAssertFalse(stroke.hasFault(.shortFinish))
        }
    }

    // MARK: - Ordering

    func testSequenceFaultOutranksRhythm() {
        let stroke = measured(
            RowingFixture.session(recoveryFrames: 22, armBreakAtDriveFraction: 0.20)
        )[0]

        XCTAssertTrue(stroke.hasFault(.rushingTheRecovery))
        XCTAssertEqual(
            stroke.faults.first?.kind, .sequenceArmsTooEarly,
            "faults.first is what the athlete is told, and sequencing is the correction to make first"
        )
    }

    // MARK: - Scale references

    func testBothScaleCandidatesAreCarriedForComparison() {
        let stroke = measured(RowingFixture.session())[0]

        XCTAssertEqual(stroke.torsoScaleSample!, 0.25, accuracy: 0.005)
        XCTAssertEqual(stroke.shinScaleSample!, 0.16, accuracy: 0.005)
    }
}
