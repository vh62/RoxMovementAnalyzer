import XCTest
@testable import RoxMovementAnalyzer

/// Covers the burpee branch of the session analyzer, and that the station-neutral types carrying the
/// timeline, the overlay and the scorecard now carry a fourth station without special-casing it.
final class BurpeeScorecardTests: XCTestCase {

    private let analyzer = PoseSessionAnalyzer()

    private func score(_ frames: [PoseFrame]) -> StationScore {
        analyzer.analyze(station: .burpeeBroadJumps, frames: frames).stations[0]
    }

    private func metric(_ label: String, in score: StationScore) -> MetricResult? {
        score.metrics.first { $0.label == label }
    }

    // MARK: - Station vocabulary

    func testBurpeesCountValidRepsAndCallNoRepsAloud() {
        XCTAssertEqual(HyroxStation.burpeeBroadJumps.countNoun, "VALID REPS",
                       "§8.4 gives this station a judging standard, so a rep either counts or it does not")
        XCTAssertTrue(HyroxStation.burpeeBroadJumps.hasNoRepRule)
        XCTAssertTrue(HyroxStation.burpeeBroadJumps.hasMovementAnalysis)
        XCTAssertTrue(HyroxStation.burpeeBroadJumps.requiresFullBody)
    }

    func testBurpeesShowNoDepthGuideAndNoJointAngles() {
        XCTAssertFalse(HyroxStation.burpeeBroadJumps.showsDepthGuide,
                       "the parallel line is a squat-judging device — a burpee is judged against the "
                        + "floor, not against the knee")
        XCTAssertFalse(HyroxStation.burpeeBroadJumps.showsJointAngles,
                       "not one of the three rules reads a joint angle, so labelling six of them "
                        + "would give the overlay's most prominent numbers to the only quantities "
                        + "that cannot change the verdict")
    }

    func testEveryOtherStationKeepsItsJointAngles() {
        for station in HyroxStation.allCases where station != .burpeeBroadJumps {
            XCTAssertTrue(station.showsJointAngles,
                          "\(station.rawValue) is judged on joints — the hinge and the knee carry "
                            + "both ergs' power and the squat is judged hip against knee")
        }
    }

    func testNoRepPhraseIsAVerdictRatherThanTheWrongCorrection() {
        XCTAssertEqual(HyroxStation.wallBalls.noRepPhrase, "Squat lower",
                       "a wall ball fails exactly one way, so the cue can be the instruction")
        XCTAssertEqual(HyroxStation.burpeeBroadJumps.noRepPhrase, "No rep",
                       "a burpee fails three ways, and naming the wrong rule mid-set is worse than "
                        + "naming none — the screen says which")
    }

    // MARK: - Counted movements

    func testValidRepsCountAndFaultedRepsDoNot() {
        let clean = StationAnalysis.burpees(
            BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session())
        ).countedMovements
        let hovered = StationAnalysis.burpees(
            BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session(chestGap: 0.07))
        ).countedMovements

        XCTAssertFalse(clean.isEmpty)
        XCTAssertTrue(clean.allSatisfy(\.counted))
        XCTAssertFalse(hovered.isEmpty)
        XCTAssertTrue(hovered.allSatisfy { !$0.counted },
                      "every burpee fault is a rule, so any fault voids the rep")
    }

    func testCalloutJumpsToTheTakeOff() {
        let reps = BurpeeRepAnalyzer.analyze(frames: BurpeeFixture.session())
        let movements = StationAnalysis.burpees(reps).countedMovements

        XCTAssertEqual(movements.first?.calloutSeconds, reps.first?.topSeconds,
                       "the take-off sits between the two corridor moments, so it is the frame worth "
                        + "jumping to whichever rule fired")
    }

    func testAttemptsAreReportedAsARatioBecauseARepCanFail() {
        let frames = BurpeeFixture.session(chestGap: 0.07)
        let timeline = SessionTimeline(frames: frames, station: .burpeeBroadJumps)

        XCTAssertGreaterThan(timeline.attempts(at: timeline.duration), timeline.totalCount,
                             "a set of no-reps should read 0 of 4, not 0 of 0")
    }

    // MARK: - Scoring

    func testCleanSetScoresFullAndRaisesNoAlerts() {
        let result = score(BurpeeFixture.session())

        XCTAssertEqual(result.score, 100)
        XCTAssertTrue(result.alerts.isEmpty, "alerts were \(result.alerts.map(\.title))")
        XCTAssertEqual(metric("Valid reps", in: result)?.value, "4")
        XCTAssertEqual(metric("Total reps", in: result)?.value, "4")
    }

    func testRepRateAndJumpDistanceAreReported() throws {
        let result = score(BurpeeFixture.session())

        let rate = try XCTUnwrap(metric("Rep rate", in: result))
        XCTAssertEqual(rate.value, "30/min")

        let distance = try XCTUnwrap(metric("Jump distance", in: result))
        XCTAssertTrue(distance.value.hasSuffix("torso lengths"), "was \(distance.value)")
        XCTAssertEqual(distance.status, .raceReady,
                       "rule 9 leaves the length to the racer, so this carries no judgement")
    }

    func testShortJumpsAreReportedWithoutBeingPenalised() {
        let result = score(BurpeeFixture.session(jump: 0.16))

        XCTAssertEqual(result.score, 100, "rule 9: the length of each broad jump is up to the racer")
        XCTAssertNotNil(metric("Jump distance", in: result))
    }

    func testCorridorMetricSaysWhyRatherThanOmittingItFrontOn() {
        let result = score(BurpeeFixture.session(shoulderSpread: 0.22))

        XCTAssertEqual(metric("Hand and foot rules", in: result)?.value, "Needs side view",
                       "a measurement that cannot be made honestly should say so rather than "
                        + "disappearing off the card")
        XCTAssertNotNil(metric("Chest contact", in: result),
                        "chest contact is vertical, so it survives a front-on camera")
    }

    func testFaultedSetRaisesOneAlertPerKind() {
        let result = score(
            BurpeeFixture.session(toeLead: 0.08, handsAhead: 0.13, chestGap: 0.07)
        )

        XCTAssertEqual(result.alerts.count, 3, "one per kind, not one per rep — "
            + "\(result.alerts.map(\.title))")
        XCTAssertEqual(Set(result.alerts.map(\.title)).count, 3)
        XCTAssertEqual(result.score, 0, "every rep breached a rule")
    }

    func testAlertsComeOutInCoachingPriorityOrder() {
        let result = score(
            BurpeeFixture.session(toeLead: 0.08, handsAhead: 0.13, chestGap: 0.07)
        )

        XCTAssertEqual(
            result.alerts.map(\.title),
            ["Hands too far forward", "Feet past the hands", "Chest not down"],
            "the scorecard orders alerts by `BurpeeFault.Kind.allCases`, which is coaching priority — "
                + "hand placement first, because it is what causes the feet to overshoot"
        )
    }

    func testNoRepsReportsHonestlyRatherThanScoringZeroSilently() {
        let result = score(BurpeeFixture.stillFrames())

        XCTAssertEqual(result.score, 0)
        XCTAssertEqual(result.status, .needsWork)
        XCTAssertTrue(result.primaryFeedback.contains("No burpee broad jumps were detected"))
        XCTAssertTrue(result.primaryFeedback.contains("80 m"),
                      "the athlete needs to know a static phone only catches a few reps, or they "
                        + "will think the app failed")
    }

    func testFeedbackNamesTheRuleItCannotCheck() {
        let result = score(BurpeeFixture.session())

        XCTAssertTrue(result.primaryFeedback.contains("5 cm"),
                      "the foot-stagger tolerance is a real rule that is deliberately not checked, "
                        + "and saying so is what stops a clean score reading as a clean rep")
    }

    // MARK: - Timeline and shared plumbing

    func testTimelineCountsBurpeesAndSurfacesFaultsThroughTheSharedCallout() throws {
        let frames = BurpeeFixture.session(toeLead: 0.08)
        let timeline = SessionTimeline(frames: frames, station: .burpeeBroadJumps)

        XCTAssertEqual(timeline.totalCount, 0, "every rep broke rule 5, so none of them counted")

        let reps = BurpeeRepAnalyzer.analyze(frames: frames)
        let rep = try XCTUnwrap(reps.first)

        // The banner is keyed to where the movement *ends*, which is the shared convention across
        // every station — `calloutSeconds` is where the replay jumps to, not when the banner shows.
        let callout = try XCTUnwrap(timeline.activeFault(at: rep.endSeconds))

        XCTAssertEqual(callout.title, "Feet past the hands")
        XCTAssertEqual(callout.kindIdentifier, BurpeeFault.Kind.feetPastFingertips.rawValue,
                       "the scorecard aggregates on this without knowing the station")

        XCTAssertNil(timeline.activeFault(at: rep.endSeconds + SessionTimeline.faultCalloutWindow + 0.1),
                     "and it fades, rather than sitting on screen into the next rep")
    }

    func testFramingCueNamesTheFloorRatherThanOverhead() {
        let cue = StationRuleLiveFeedbackGenerator().framingCue(for: .burpeeBroadJumps)

        XCTAssertTrue(cue.detail.contains("bottom"),
                      "burpees are the one station that loses the hands at the bottom, so the "
                        + "instruction is the opposite of every other station's")
        XCTAssertFalse(cue.message.contains("overhead"))
    }
}
