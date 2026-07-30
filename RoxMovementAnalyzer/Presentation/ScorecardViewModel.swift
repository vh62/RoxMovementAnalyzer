import Foundation

@Observable
final class ScorecardViewModel {
    let scorecard: WorkoutScorecard
    let summary: ScorecardSummary

    convenience init(
        scorecardProvider: ScorecardProviding = SampleScorecardProvider(),
        analyzer: ScorecardAnalyzing = EqualWeightScorecardAnalyzer()
    ) {
        self.init(scorecard: scorecardProvider.loadScorecard(), analyzer: analyzer)
    }

    init(
        scorecard: WorkoutScorecard,
        analyzer: ScorecardAnalyzing = EqualWeightScorecardAnalyzer()
    ) {
        self.scorecard = scorecard
        self.summary = analyzer.summarize(scorecard)
    }
}