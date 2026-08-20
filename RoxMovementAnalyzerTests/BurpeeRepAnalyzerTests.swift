import XCTest
@testable import RoxMovementAnalyzer

/// Segmentation and rule judgement for burpee broad jumps.
///
/// A third of this file tests that the analyzer stays **quiet**. §8.4 permits a great deal that looks
/// like a fault — stepping out of and back into the burpee, coming up off a knee, a short jump, a
/// chest that touches without the thighs — and a checker written from general burpee coaching rather
/// than from the rulebook would fault every one of them. Those tests are the point, not the padding.
final class BurpeeRepAnalyzerTests: XCTestCase {
    private let thresholds = BurpeeThresholds.default

    // MARK: - Segmentation

    func testSessionSegmentsIntoRepsBoundedByChestContacts() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(cycles: 5))

        XCTAssertEqual(reps.count, 4, "a rep is bounded by two chest contacts, so 5 contacts yield 4 "
            + "reps — the trailing partial has no broad jump yet and is discarded")
    }

    func testRepIndicesAreContiguousFromZero() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session())

        XCTAssertEqual(reps.map(\.index), Array(0..<reps.count),
                       "indices address the replay scrubber, so they cannot skip")
    }

    func testRepPhasesArriveInTheOrderTheAthletePerformsThem() throws {
        let rep = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).first)

        XCTAssertLessThan(rep.startSeconds, rep.topSeconds,
                          "the chest contact opens the rep and the take-off follows it")
        XCTAssertLessThan(rep.topSeconds, rep.endSeconds,
                          "the next chest contact closes the rep after the take-off")
    }

    func testRepDurationMatchesTheFixtureCadence() throws {
        let rep = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last)

        // Five 12-frame phases at 30 fps is two seconds a rep — 30 reps a minute.
        XCTAssertEqual(rep.durationSeconds, 2.0, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(rep.repRate), 30, accuracy: 3)
    }

    func testStillAthleteYieldsNoReps() {
        XCTAssertTrue(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.stillFrames()).isEmpty,
                      "an athlete standing at the line has not started")
    }

    func testShallowBobbingIsNotARep() {
        XCTAssertTrue(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.shallowBobs()).isEmpty,
                      "a dip that never approaches the floor is below minChestRange — someone "
                        + "catching their breath, not a burpee")
    }

    func testTrackingGapDiscardsTheRepItFallsIn() {
        let clean = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session())
        let gapped = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(gapFramesInSecondRep: 15))

        XCTAssertLessThan(gapped.count, clean.count,
                          "half a second of lost tracking can hide the frames where the feet were "
                            + "furthest forward, which would turn a no-rep into a clean rep")
    }

    // MARK: - The clean rep

    func testCleanSessionRaisesNothing() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session())

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "the clean rep is load-bearing: every fault test below "
                + "means nothing if the default fixture already fires something")
            XCTAssertTrue(rep.isValid)
        }
    }

    func testMirroredSessionMeasuresTheSameAsUnmirrored() throws {
        let forward = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last)
        let mirrored = try XCTUnwrap(
            BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(mirrored: true)).last
        )

        XCTAssertEqual(mirrored.facing, .left, "mirroring the frame reverses the direction of travel")
        XCTAssertEqual(forward.facing, .right)
        XCTAssertEqual(try XCTUnwrap(mirrored.toeBeyondFingertips),
                       try XCTUnwrap(forward.toeBeyondFingertips), accuracy: 0.02,
                       "the corridor is measured along the athlete's own forward axis, so which way "
                        + "they face cannot change the verdict")
        XCTAssertEqual(try XCTUnwrap(mirrored.handsAheadOfFrontToe),
                       try XCTUnwrap(forward.handsAheadOfFrontToe), accuracy: 0.02)
        XCTAssertEqual(mirrored.faults, [])
    }

    // MARK: - What the rulebook permits (and a coaching-led checker would fault)

    func testSteppingOutOfTheBurpeeIsLegal() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(stepOut: true))

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "rule 3 permits jumping *or stepping* out of the burpee. "
                + "The feet come up one at a time here, with a dwell between, and that must neither "
                + "split the rep nor disturb where rule 5 is read")
        }
    }

    func testSteppingBackIntoTheBurpeeIsLegal() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(stepBack: true))

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "rule 7 permits jumping *or stepping* backwards into the "
                + "burpee position once the hands are down")
        }
    }

    func testSteppingAtBothEndsOfTheRepIsLegal() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(stepOut: true, stepBack: true))

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "rules 3 and 7 together permit a rep with no jump in it "
                + "except the broad jump itself")
        }
    }

    func testShortBroadJumpIsLegalAndStillMeasured() throws {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(jump: 0.16))

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "rule 9: the length of each broad jump is up to the racer, "
                + "so a short jump can never be a fault")
        }

        let short = try XCTUnwrap(reps.last?.jumpDistance)
        let normal = try XCTUnwrap(
            BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last?.jumpDistance
        )
        XCTAssertLessThan(short, normal, "it is still reported, because it is what decides how many "
            + "reps 80 m costs")
    }

    // MARK: - Rule 5: the feet cannot pass the fingertips

    func testFeetLandingPastTheFingertipsIsANoRep() throws {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(toeLead: 0.08))

        let rep = try XCTUnwrap(reps.last)
        XCTAssertTrue(rep.hasFault(.feetPastFingertips), "faults were \(rep.faults)")
        XCTAssertFalse(rep.isValid, "every burpee fault is a rule, so any fault voids the rep")
        XCTAssertGreaterThan(try XCTUnwrap(rep.toeBeyondFingertips),
                             thresholds.feetPastFingertipsMargin)
    }

    func testFeetInsideTheFingertipsClearsRuleFive() throws {
        let rep = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last)

        XCTAssertLessThan(try XCTUnwrap(rep.toeBeyondFingertips), 0,
                          "a clean rep brings the feet up *to* the hands, so the toe stays behind "
                            + "the fingertips and the measurement is negative")
        XCTAssertFalse(rep.hasFault(.feetPastFingertips))
    }

    // MARK: - Rule 6: the hands go down within 30 cm of the front toe

    func testHandsPlantedTooFarForwardIsANoRep() throws {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(handsAhead: 0.13))

        let rep = try XCTUnwrap(reps.last)
        XCTAssertTrue(rep.hasFault(.handsTooFarForward), "faults were \(rep.faults)")
        XCTAssertGreaterThan(try XCTUnwrap(rep.handsAheadOfFrontToe),
                             thresholds.maxHandsAheadOfFrontToe)
    }

    func testHandsPlantedCloseToTheToesClearRuleSix() throws {
        let rep = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last)

        XCTAssertLessThan(try XCTUnwrap(rep.handsAheadOfFrontToe),
                          thresholds.maxHandsAheadOfFrontToe)
        XCTAssertFalse(rep.hasFault(.handsTooFarForward))
    }

    // MARK: - Rule 2a and 7: the chest touches

    func testChestHeldOffTheFloorIsANoRep() throws {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(chestGap: 0.07))

        let rep = try XCTUnwrap(reps.last)
        XCTAssertTrue(rep.hasFault(.chestNotDown), "faults were \(rep.faults)")
        XCTAssertGreaterThan(rep.bottomChestHeight, thresholds.maxChestContactHeight)
    }

    func testHoveredRepIsStillCountedAsAnAttempt() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(chestGap: 0.07))

        XCTAssertEqual(reps.count, 4, "a rep that misses chest contact must be **segmented and "
            + "faulted**, not discarded — an analyzer that dropped it would fall silent on the "
            + "failure it exists to report")
        XCTAssertTrue(reps.allSatisfy { !$0.isValid })
    }

    func testVerdictDoesNotDependOnTheFrameRate() throws {
        // The same two seconds of motion, sampled four times as often — 120 fps is what an iPhone
        // captures in slo-mo. Every threshold in the analyzer is an angle, a ratio or a distance, so
        // the sample rate must not move a verdict or a measurement.
        let thirty = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(toeLead: 0.08))
        let oneTwenty = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(toeLead: 0.08, phaseFrames: 48, frameRate: 120)
        )

        XCTAssertEqual(oneTwenty.count, thirty.count)
        XCTAssertEqual(oneTwenty.map { $0.faults.map(\.kind) }, thirty.map { $0.faults.map(\.kind) },
                       "a rule broken at 30 fps has to still be broken at 120")

        let fast = try XCTUnwrap(oneTwenty.last)
        let slow = try XCTUnwrap(thirty.last)
        XCTAssertEqual(try XCTUnwrap(fast.jumpDistance), try XCTUnwrap(slow.jumpDistance),
                       accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(fast.toeBeyondFingertips),
                       try XCTUnwrap(slow.toeBeyondFingertips), accuracy: 0.05)
    }

    func testCleanRepStaysCleanAtAHigherFrameRate() {
        let reps = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(phaseFrames: 48, frameRate: 120)
        )

        XCTAssertFalse(reps.isEmpty)
        for rep in reps {
            XCTAssertEqual(rep.faults, [], "a finer sample rate must not manufacture a translation "
                + "out of the same smooth motion")
        }
    }

    func testCleanRepReportsItsJumpDistance() throws {
        let rep = try XCTUnwrap(BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session()).last)

        XCTAssertGreaterThan(try XCTUnwrap(rep.jumpDistance), 1.0,
                             "the distance covered with the hands off the deck — reported because it "
                                + "decides how many reps 80 m costs, never faulted because rule 9 "
                                + "leaves it to the racer")
    }

    // MARK: - Suppression

    func testFrontOnSuppressesTheCorridorButStillJudgesTheChest() throws {
        let corridorBreach = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(toeLead: 0.08, handsAhead: 0.13, shoulderSpread: 0.22)
        )
        let rep = try XCTUnwrap(corridorBreach.last)

        XCTAssertEqual(rep.viewpoint, .frontOn)
        XCTAssertEqual(rep.faults, [], "a front-on camera cannot measure along the direction of "
            + "travel, so every horizontal rule is suppressed rather than guessed at")

        let hovered = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(chestGap: 0.07, shoulderSpread: 0.22)
        )
        XCTAssertTrue(try XCTUnwrap(hovered.last).hasFault(.chestNotDown),
                      "chest contact is a *vertical* measurement, so it survives front-on — the "
                        + "station goes quiet on what it cannot see and keeps judging what it can")
    }

    func testLostHandsSuppressEveryHandDependentRuleWithoutInventingOne() throws {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(handsVisible: false))

        XCTAssertEqual(reps.count, 4, "segmentation runs on the shoulders and ankles, so losing the "
            + "wrists costs the rules and none of the counting")

        let rep = try XCTUnwrap(reps.last)
        XCTAssertFalse(rep.handsTracked, "which is what raises the framing cue")
        XCTAssertNil(rep.toeBeyondFingertips)
        XCTAssertNil(rep.handsAheadOfFrontToe)
        XCTAssertNil(rep.jumpDistance, "the jump window is bounded by where the hands are, so "
            + "without them it is unknown — and an unknown window must suppress rather than expand "
            + "to cover the whole rep, which would fold the long backward travel into the burpee "
            + "position into the reported distance")
        XCTAssertEqual(rep.faults, [])
    }

    func testChestContactIsJudgedEvenWithoutTheHands() throws {
        let reps = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(chestGap: 0.07, handsVisible: false)
        )

        XCTAssertTrue(try XCTUnwrap(reps.last).hasFault(.chestNotDown),
                      "chest height needs the shoulders and ankles, not the wrists")
    }

    // MARK: - Priority

    func testHandPlacementIsReportedAheadOfEverythingElse() throws {
        let reps = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(toeLead: 0.08, handsAhead: 0.13, chestGap: 0.07)
        )
        let rep = try XCTUnwrap(reps.last)

        XCTAssertEqual(rep.faults.count, 3, "faults were \(rep.faults)")
        XCTAssertEqual(rep.faults.first?.kind, .handsTooFarForward,
                       "`faults.first` is what the athlete is told. Hands planted out in front are "
                        + "what force the feet to overshoot them on the way up, so rule 6 is the "
                        + "cause and rule 5 is the effect — fixing the cause fixes both")
    }

    func testCorridorIsReportedAheadOfChestContact() throws {
        let reps = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(toeLead: 0.08, chestGap: 0.07)
        )
        let rep = try XCTUnwrap(reps.last)

        XCTAssertEqual(rep.faults.count, 2, "faults were \(rep.faults)")
        XCTAssertEqual(rep.faults.first?.kind, .feetPastFingertips,
                       "a missed chest is the failure the athlete can already feel — both placement "
                        + "rules are the ones they cannot")
    }

    func testFaultOrderMatchesTheDeclaredCoachingPriority() throws {
        let reps = BurpeeRepAnalyzer.analyze(
            frames: BurpeeFixture.session(toeLead: 0.08, handsAhead: 0.13, chestGap: 0.07)
        )
        let rep = try XCTUnwrap(reps.last)

        let declared = BurpeeFault.Kind.allCases
        let reported = rep.faults.map(\.kind)
        XCTAssertEqual(reported, declared.filter(reported.contains),
                       "`Kind.allCases` drives scorecard alert ordering, so it has to agree with the "
                        + "order the analyzer appends in")
    }
}
