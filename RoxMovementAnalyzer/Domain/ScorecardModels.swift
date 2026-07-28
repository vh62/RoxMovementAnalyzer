import Foundation

struct WorkoutScorecard {
    let athleteName: String
    let sessionName: String
    let sessionDate: Date
    let stations: [StationScore]
}

enum HyroxStation: String, CaseIterable, Identifiable {
    case skiErg = "SkiErg"
    case wallBalls = "Wall Balls"
    case sledPush = "Sled Push"
    case sledPull = "Sled Pull"
    case burpeeBroadJumps = "Burpee Broad Jumps"
    case rowing = "Rowing"
    case running = "Running"
    case lunges = "Lunges"

    var id: String { rawValue }
}

struct StationScore: Identifiable {
    var id: HyroxStation { station }

    let station: HyroxStation
    let score: Int
    let status: StationStatus
    let primaryFeedback: String
    let metrics: [MetricResult]
    let alerts: [RedFlagAlert]
}

struct MetricResult: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let status: StationStatus
}

struct RedFlagAlert: Identifiable {
    let id = UUID()
    let station: HyroxStation
    let title: String
    let message: String
    let severity: AlertSeverity
    let timestamp: TimeInterval?
}

enum AlertSeverity: String {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var sortPriority: Int {
        switch self {
        case .high: 3
        case .medium: 2
        case .low: 1
        }
    }
}

enum StationStatus: String {
    case strong = "Strong"
    case raceReady = "Race Ready"
    case caution = "Caution"
    case needsWork = "Needs Work"
}

enum TechniqueRating: String {
    case elite = "Elite"
    case raceReady = "Race Ready"
    case developing = "Developing"
    case highRisk = "High Risk"

    init(score: Int) {
        switch score {
        case 90...100: self = .elite
        case 78..<90: self = .raceReady
        case 60..<78: self = .developing
        default: self = .highRisk
        }
    }
}

struct ScorecardSummary {
    let overallScore: Int
    let rating: TechniqueRating
    let criticalAlerts: [RedFlagAlert]
    let topRecommendations: [String]
}