import SwiftUI

extension HyroxStation {
    var symbolName: String {
        switch self {
        case .skiErg: "figure.skiing.crosscountry"
        case .wallBalls: "figure.strengthtraining.traditional"
        case .sledPush: "arrow.forward.to.line"
        case .sledPull: "arrow.backward.to.line"
        case .burpeeBroadJumps: "figure.run"
        case .rowing: "figure.rower"
        case .running: "figure.run.circle"
        case .lunges: "figure.step.training"
        }
    }

    var ruleSummary: String {
        switch self {
        case .skiErg:
            "Hips hinge before the pull, lats stay connected, and peak force arrives through the drive phase."
        case .wallBalls:
            "Hips sink below knees before ball release."
        case .sledPush:
            "Back angle stays under 45 deg for strong forward drive."
        case .sledPull:
            "Arms stay extended, hips remain low, and rope tension stays consistent."
        case .burpeeBroadJumps:
            "Chest contact, aligned feet, close hands, and jump distance all pass."
        case .rowing:
            "Stroke sequence follows legs, then back, then arms."
        case .running:
            "Stride symmetry holds while cadence stays in the target range."
        case .lunges:
            "Rear knee contacts ground with balanced stride and hip-loaded mechanics."
        }
    }
}

extension AlertSeverity {
    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .yellow
        }
    }
}

extension RedFlagAlert {
    var timestampLabel: String? {
        guard let timestamp else { return nil }
        let minutes = Int(timestamp) / 60
        let seconds = Int(timestamp) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

extension StationStatus {
    var color: Color {
        switch self {
        case .strong: .green
        case .raceReady: .teal
        case .caution: .orange
        case .needsWork: .red
        }
    }

    var symbolName: String {
        switch self {
        case .strong: "checkmark.circle.fill"
        case .raceReady: "checkmark.seal.fill"
        case .caution: "exclamationmark.triangle.fill"
        case .needsWork: "xmark.octagon.fill"
        }
    }
}

extension TechniqueRating {
    var color: Color {
        switch self {
        case .elite: .green
        case .raceReady: .teal
        case .developing: .orange
        case .highRisk: .red
        }
    }

    var summary: String {
        switch self {
        case .elite:
            "Technique held under fatigue with only small refinements needed."
        case .raceReady:
            "Strong session with a few rule checks to clean up before race day."
        case .developing:
            "Good base, but key stations need attention before intensity increases."
        case .highRisk:
            "Prioritize movement quality before chasing faster splits."
        }
    }
}

enum AppTheme {
    static let background = Color(red: 0.96, green: 0.97, blue: 0.95)
    static let ink = Color(red: 0.08, green: 0.11, blue: 0.12)
    static let muted = Color(red: 0.38, green: 0.43, blue: 0.43)
}