import XCTest
@testable import RoxMovementAnalyzer

/// Covers the rowing branch of the session analyzer, and the station-neutral types that let two
/// stations share the timeline, the overlay and the scorecard.
final class RowingScorecardTests: XCTestCase {

    private let analyzer = PoseSessionAnalyzer()

    // MARK: - Station vocabulary

    func testRowingCountsStrokesRatherThanValidReps() {
        XCTAssertEqual(HyroxStation.wallBalls.countNoun, "VALID REPS")
        XCTAssertEqual(
            HyroxStation.rowing.countNoun, "STROKES",
            "every stroke counts on an erg, so calling one a valid rep would import a judging "
                + "concept rowing does not have"
        )
    }

    func testOnlyWallBallsHasANoRepRule() {
        XCTAssertTrue(HyroxStation.wallBalls.hasNoRepRule)
        XCTAssertFalse(
            HyroxStation.rowing.hasNoRepRule,
            "a rowing stroke cannot fail to count, so nothing should ever call one aloud"
        )
    }

    func testDepthGuideIsWallBallsOnlyButBothStationsAreAnalysed() {
        XCTAssertTrue(HyroxStation.wallBalls.showsDepthGuide)
        XCTAssertFalse(
            HyroxStation.rowing.showsDepthGuide,
            "the parallel line is a squat-judging device and means nothing on a seated athlete"
        )

        XCTAssertTrue(HyroxStation.rowing.hasMovementAnalysis)
        XCTAssertTrue(HyroxStation.rowing.requiresFullBody)
        XCTAssertFalse(HyroxStation.running.hasMovementAnalysis)
    }

    func testRowingMovementsAlwaysCount() {
        let strokes = RowStrokeAnalyzer.analyze(frames: RowingFixture.session())
        let movements = StationAnalysis.rowing(strokes).countedMovements

        XCTAssertFalse(movements.isEmpty)
        XCTAssertTrue(
            movements.allSatisfy(\.counted),
            "the erg logs the metres whatever the stroke looked like"
        )
    }

    func testRowingAttemptsMatchTheStrokeCount() {
        let timeline = SessionTimeline(frames: RowingFixture.session(), station: .rowing)

        XCTAssertEqual(
            timeline.attempts(at: timeline.duration), timeline.totalCount,
            "every stroke counts, so a ratio would always be 1:1 and tell the athlete nothing"
        )
    }

    // MARK: - Scorecard

    func testCleanPieceScoresWellAndRaisesNoAlerts() {
        let score = analyzer
            .analyze(station: .rowing, frames: RowingFixture.session())
            .stations[0]

        XCTAssertEqual(score.station, .rowing)
        XCTAssertEqual(score.score, 100)
        XCTAssertTrue(score.alerts.isEmpty)
        XCTAssertTrue(score.metrics.contains { $0.label == "Strokes" })
    }

    func testStrokeRateAndRatioAreReported() {
        let score = analyzer
            .analyze(station: .rowing, frames: RowingFixture.session())
            .stations[0]

        let rate = score.metrics.first { $0.label == "Stroke rate" }
        XCTAssertNotNil(rate, "stroke rate is a metric, never a fault — the right rate is the athlete's")
        XCTAssertTrue(rate!.value.hasSuffix("spm"))

        let ratio = score.metrics.first { $0.label == "Drive:recovery" }
        XCTAssertNotNil(ratio)
        XCTAssertTrue(ratio!.value.hasPrefix("1:"))
    }

    func testFaultedPieceRaisesOneAlertPerKind() {
        let score = analyzer
            .analyze(
                station: .rowing,
                frames: RowingFixture.session(recoveryFrames: 22, armBreakAtDriveFraction: 0.20)
            )
            .stations[0]

        let titles = score.alerts.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "one alert per kind, not one per stroke")
        XCTAssertTrue(score.alerts.contains { $0.title == "Arms broke early" })
        XCTAssertTrue(score.alerts.contains { $0.title == "Rushing the recovery" })
        XCTAssertLessThan(score.score, 100)
    }

    func testAlertsComeOutInCoachingPriorityOrder() {
        let score = analyzer
            .analyze(
                station: .rowing,
                frames: RowingFixture.session(recoveryFrames: 22, armBreakAtDriveFraction: 0.20)
            )
            .stations[0]

        let arms = score.alerts.firstIndex { $0.title == "Arms broke early" }
        let rhythm = score.alerts.firstIndex { $0.title == "Rushing the recovery" }

        XCTAssertNotNil(arms)
        XCTAssertNotNil(rhythm)
        XCTAssertLessThan(arms!, rhythm!, "sequencing is the correction to make before rhythm")
    }

    func testNoStrokesReportsHonestlyRatherThanScoringZeroSilently() {
        let score = analyzer.analyze(station: .rowing, frames: RowingFixture.stillFrames()).stations[0]

        XCTAssertEqual(score.score, 0)
        XCTAssertEqual(score.status, .needsWork)
        XCTAssertTrue(score.primaryFeedback.contains("No rowing strokes were detected"))
    }

    func testFeedbackSaysTheScoreIsNotARuleCheck() {
        let score = analyzer
            .analyze(station: .rowing, frames: RowingFixture.session())
            .stations[0]

        XCTAssertTrue(
            score.primaryFeedback.contains("Every stroke counts"),
            "the athlete must not read this as a legality judgement the way depth accuracy is"
        )
        XCTAssertTrue(score.primaryFeedback.contains("starting estimates"))
    }

    // MARK: - Timeline

    func testTimelineCountsStrokesForRowing() {
        let timeline = SessionTimeline(frames: RowingFixture.session(), station: .rowing)

        XCTAssertFalse(timeline.isEmpty)
        XCTAssertGreaterThan(timeline.totalCount, 0)
        XCTAssertFalse(timeline.movements.isEmpty)

        if case .rowing = timeline.analysis {} else {
            XCTFail("the timeline should carry the rowing analysis")
        }
    }

    func testTimelineSurfacesRowingFaultsThroughTheSharedCallout() {
        let timeline = SessionTimeline(
            frames: RowingFixture.session(armBreakAtDriveFraction: 0.20),
            station: .rowing
        )

        let faulted = try? XCTUnwrap(timeline.faultedMovements.last)
        XCTAssertNotNil(faulted)
        XCTAssertEqual(
            timeline.activeFault(at: faulted!.endSeconds + 0.2)?.title, "Arms broke early"
        )

        // Measured off the last faulted stroke: every stroke in this piece is faulted, so any
        // earlier one would still be inside the *next* stroke's callout window.
        XCTAssertNil(
            timeline.activeFault(at: faulted!.endSeconds + SessionTimeline.faultCalloutWindow + 0.1),
            "the callout fades rather than sticking for the rest of the video"
        )
    }
}
