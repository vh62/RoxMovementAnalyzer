import Foundation

@Observable
final class ScorecardViewModel {
    let scorecard: WorkoutScorecard
    let summary: ScorecardSummary

    init(
        scorecardProvider: ScorecardProviding = SampleScorecardProvider(),
        analyzer: ScorecardAnalyzing = EqualWeightScorecardAnalyzer()
    ) {
        let scorecard = scorecardProvider.loadScorecard()
        self.scorecard = scorecard
        self.summary = analyzer.summarize(scorecard)
    }
}