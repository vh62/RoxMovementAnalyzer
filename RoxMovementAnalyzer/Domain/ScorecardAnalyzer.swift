import Foundation

protocol ScorecardAnalyzing {
    func summarize(_ scorecard: WorkoutScorecard) -> ScorecardSummary
}

struct EqualWeightScorecardAnalyzer: ScorecardAnalyzing {
    func summarize(_ scorecard: WorkoutScorecard) -> ScorecardSummary {
        let overallScore = calculateOverallScore(for: scorecard.stations)
        let criticalAlerts = sortedAlerts(from: scorecard.stations)

        return ScorecardSummary(
            overallScore: overallScore,
            rating: TechniqueRating(score: overallScore),
            criticalAlerts: criticalAlerts,
            topRecommendations: Array(criticalAlerts.prefix(3).map(\.message))
        )
    }

    private func calculateOverallScore(for stations: [StationScore]) -> Int {
        guard !stations.isEmpty else { return 0 }
        let totalScore = stations.reduce(0) { $0 + $1.score }
        return Int((Double(totalScore) / Double(stations.count)).rounded())
    }

    private func sortedAlerts(from stations: [StationScore]) -> [RedFlagAlert] {
        stations
            .flatMap(\.alerts)
            .sorted { leftAlert, rightAlert in
                if leftAlert.severity.sortPriority == rightAlert.severity.sortPriority {
                    return (leftAlert.timestamp ?? 0) < (rightAlert.timestamp ?? 0)
                }

                return leftAlert.severity.sortPriority > rightAlert.severity.sortPriority
            }
    }
}