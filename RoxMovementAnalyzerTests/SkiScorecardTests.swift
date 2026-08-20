import XCTest
@testable import RoxMovementAnalyzer

/// Covers the SkiErg branch of the session analyzer, and that the station-neutral types carrying the
/// timeline, the overlay and the scorecard now carry a third station without special-casing it.
final class SkiScorecardTests: XCTestCase {

    private let analyzer = PoseSessionAnalyzer()

    // MARK: - Station vocabulary

    func testSkiErgShowsNoCounterBecauseTheMachineAlreadyHasOne() {
        XCTAssertNil(
            HyroxStation.skiErg.countNoun,
            "the SkiErg monitor already counts pulls from its own flywheel — this station's job is to "
                + "say how each pull was made, which is the thing the monitor cannot"
        )
    }

    func testSkiErgHasNoNoRepRuleAndNoDepthGuide() {
        XCTAssertFalse(
            HyroxStation.skiErg.hasNoRepRule,
            "a SkiErg pull cannot fail to count, so nothing should ever call one aloud"
        )
        XCTAssertFalse(
            HyroxStation.skiErg.showsDepthGuide,
            "the parallel line is a squat-judging device and means nothing at a SkiErg"
        )

        XCTAssertTrue(HyroxStation.skiErg.hasMovementAnalysis)
        XCTAssertTrue(HyroxStation.skiErg.requiresFullBody)
    }

    func testSkiErgMovementsAlwaysCount() {
        let pulls = SkiPullAnalyzer.analyze(frames: SkiFixture.session())
        let movements = StationAnalysis.skiErg(pulls).countedMovements

        XCTAssertFalse(movements.isEmpty)
        XCTAssertTrue(
            movements.allSatisfy(\.counted),
            "the machine logs the metres whatever the pull looked like"
        )
        XCTAssertEqual(
            movements.first?.calloutSeconds, pulls.first?.finishSeconds,
            "the replay should jump to the finish, which is where the error is visible"
        )
    }

    func testSkiErgAttemptsMatchThePullCount() {
        let timeline = SessionTimeline(frames: SkiFixture.session(), station: .skiErg)

        XCTAssertEqual(
            timeline.attempts(at: timeline.duration), timeline.totalCount,
            "every pull counts, so a ratio would always be 1:1 and tell the athlete nothing"
        )
    }

    // MARK: - Scorecard

    func testCleanPieceScoresWellAndRaisesNoAlerts() {
        let score = analyzer.analyze(station: .skiErg, frames: SkiFixture.session()).stations[0]

        XCTAssertEqual(score.station, .skiErg)
        XCTAssertEqual(score.score, 100)
        XCTAssertTrue(score.alerts.isEmpty)
        XCTAssertTrue(score.metrics.contains { $0.label == "Pulls" })
    }

    func testPullRateAndRatioAreReported() {
        let score = analyzer.analyze(station: .skiErg, frames: SkiFixture.session()).stations[0]

        let rate = score.metrics.first { $0.label == "Pull rate" }
        XCTAssertNotNil(rate, "pull rate is a metric, never a fault — the right rate is the athlete's")
        XCTAssertTrue(rate!.value.hasSuffix("/min"))

        let ratio = score.metrics.first { $0.label == "Drive:recovery" }
        XCTAssertNotNil(ratio, "rhythm is reported but never judged — the right rhythm is the athlete's")
        XCTAssertTrue(ratio!.value.hasPrefix("1:"))

        let peak = score.metrics.first { $0.label == "Power peak" }
        XCTAssertNotNil(peak)
        XCTAssertTrue(peak!.value.hasSuffix("% in"))

        let hinge = score.metrics.first { $0.label == "Hip hinge" }
        XCTAssertNotNil(hinge)
        XCTAssertTrue(hinge!.value.hasSuffix("°"))
    }

    func testHingeMetricSaysWhyRatherThanOmittingItFrontOn() {
        let score = analyzer
            .analyze(station: .skiErg, frames: SkiFixture.session(shoulderSpread: 0.22))
            .stations[0]

        XCTAssertEqual(score.metrics.first { $0.label == "Hip hinge" }?.value, "Needs side view")
    }

    func testFaultedPieceRaisesOneAlertPerKind() {
        let score = analyzer
            .analyze(station: .skiErg, frames: SkiFixture.session(drivePeakFraction: 0.85, finishLean: 20))
            .stations[0]

        let titles = score.alerts.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "one alert per kind, not one per pull")
        XCTAssertTrue(score.alerts.contains { $0.title == "Squatting, not hinging" })
        XCTAssertTrue(score.alerts.contains { $0.title == "Power comes too late" })
        XCTAssertLessThan(score.score, 100)
    }

    func testAlertsComeOutInCoachingPriorityOrder() {
        let score = analyzer
            .analyze(station: .skiErg, frames: SkiFixture.session(drivePeakFraction: 0.85, finishLean: 20))
            .stations[0]

        let hinge = score.alerts.firstIndex { $0.title == "Squatting, not hinging" }
        let power = score.alerts.firstIndex { $0.title == "Power comes too late" }

        XCTAssertNotNil(hinge)
        XCTAssertNotNil(power)
        XCTAssertLessThan(
            hinge!, power!,
            "a pull with no hinge has no power to place, so the hinge is the correction to make first"
        )
    }

    func testNoPullsReportsHonestlyRatherThanScoringZeroSilently() {
        let score = analyzer.analyze(station: .skiErg, frames: SkiFixture.stillFrames()).stations[0]

        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(score.status, .needsWork)
        XCTAssertTrue(score.primaryFeedback.contains("No SkiErg pulls were detected"))
    }

    func testFeedbackSaysTheScoreIsNotARuleCheck() {
        let score = analyzer.analyze(station: .skiErg, frames: SkiFixture.session()).stations[0]

        XCTAssertTrue(
            score.primaryFeedback.contains("Every pull counts"),
            "the athlete must not read this as a legality judgement the way depth accuracy is"
        )
        XCTAssertTrue(score.primaryFeedback.contains("starting estimates"))
    }

    // MARK: - Timeline

    func testTimelineCountsPullsForSkiErg() {
        let timeline = SessionTimeline(frames: SkiFixture.session(), station: .skiErg)

        XCTAssertFalse(timeline.isEmpty)
        XCTAssertGreaterThan(timeline.totalCount, 0)
        XCTAssertFalse(timeline.movements.isEmpty)

        if case .skiErg = timeline.analysis {} else {
            XCTFail("the timeline should carry the SkiErg analysis")
        }
    }

    func testTimelineSurfacesSkiFaultsThroughTheSharedCallout() {
        let timeline = SessionTimeline(
            frames: SkiFixture.session(finishLean: 20),
            station: .skiErg
        )

        let faulted = timeline.faultedMovements.last
        XCTAssertNotNil(faulted)
        XCTAssertEqual(
            timeline.activeFault(at: faulted!.endSeconds + 0.2)?.title, "Squatting, not hinging"
        )

        // Measured off the last faulted pull: every pull in this piece is faulted, so any earlier one
        // would still be inside the *next* pull's callout window.
        XCTAssertNil(
            timeline.activeFault(at: faulted!.endSeconds + SessionTimeline.faultCalloutWindow + 0.1),
            "the callout fades rather than sticking for the rest of the video"
        )
    }

    // MARK: - Live cues

    func testTheFramingCueNamesThePullRatherThanTheThrow() {
        let cue = StationRuleLiveFeedbackGenerator().framingCue(for: .skiErg)

        XCTAssertTrue(
            cue.detail.contains("top of the pull"),
            "a cue that talked about a throw would read as the app not knowing what it was watching"
        )
    }
}
