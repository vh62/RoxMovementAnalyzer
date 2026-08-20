import Foundation

protocol ScorecardProviding {
    func loadScorecard() -> WorkoutScorecard
}

struct SampleScorecardProvider: ScorecardProviding {
    func loadScorecard() -> WorkoutScorecard {
        WorkoutScorecard(
            athleteName: "Vikram",
            sessionName: "Race Simulation Review",
            sessionDate: Date(),
            stations: [
                StationScore(
                    station: .skiErg,
                    score: 84,
                    status: .raceReady,
                    primaryFeedback: "Good rhythm and lat connection. Hinge starts slightly late on fatigued pulls, shifting peak force toward the arms.",
                    metrics: [
                        MetricResult(label: "Hinge timing", value: "82%", status: .raceReady),
                        MetricResult(label: "Peak force", value: "Drive", status: .strong),
                        MetricResult(label: "Arm leak", value: "Late set", status: .caution)
                    ],
                    alerts: [
                        RedFlagAlert(station: .skiErg, title: "Late hip hinge", message: "Load the hips before pulling with the arms so the strength curve peaks during the drive, not the finish.", severity: .medium, timestamp: 38)
                    ]
                ),
                StationScore(
                    station: .wallBalls,
                    score: 86,
                    status: .raceReady,
                    primaryFeedback: "Proper squat depth on most reps. Keep hips below knees before release as fatigue rises.",
                    metrics: [
                        MetricResult(label: "Valid reps", value: "88%", status: .strong),
                        MetricResult(label: "Depth misses", value: "6", status: .caution),
                        MetricResult(label: "Release timing", value: "Good", status: .strong)
                    ],
                    alerts: [
                        RedFlagAlert(station: .wallBalls, title: "Squat too shallow", message: "Sink hips lower before the ball leaves your hands.", severity: .medium, timestamp: 74)
                    ]
                ),
                StationScore(
                    station: .sledPush,
                    score: 91,
                    status: .strong,
                    primaryFeedback: "Strong forward drive with back angle consistently under the target threshold.",
                    metrics: [
                        MetricResult(label: "Avg back angle", value: "39 deg", status: .strong),
                        MetricResult(label: "Drive phase", value: "Stable", status: .strong)
                    ],
                    alerts: []
                ),
                StationScore(
                    station: .sledPull,
                    score: 73,
                    status: .caution,
                    primaryFeedback: "Rope tension drops when the elbows bend early. Stay low and finish each pull with extended arms.",
                    metrics: [
                        MetricResult(label: "Tension", value: "71%", status: .caution),
                        MetricResult(label: "Arm bend", value: "Early", status: .needsWork),
                        MetricResult(label: "Hip height", value: "Low", status: .strong)
                    ],
                    alerts: [
                        RedFlagAlert(station: .sledPull, title: "Arms too bent", message: "Keep arms longer at the start of the pull to maintain rope tension.", severity: .high, timestamp: 142)
                    ]
                ),
                StationScore(
                    station: .rowing,
                    score: 82,
                    status: .raceReady,
                    primaryFeedback: "Stroke sequence is mostly smooth. Delay the arm pull until after the leg drive finishes.",
                    metrics: [
                        MetricResult(label: "Sequence", value: "84%", status: .strong),
                        MetricResult(label: "Early lean", value: "3 reps", status: .caution),
                        MetricResult(label: "Arm timing", value: "Late", status: .strong)
                    ],
                    alerts: [
                        RedFlagAlert(station: .rowing, title: "Leaned back too early", message: "Let the legs initiate power before opening the torso.", severity: .medium, timestamp: 312)
                    ]
                ),
                StationScore(
                    station: .running,
                    score: 79,
                    status: .raceReady,
                    primaryFeedback: "Cadence stays in range, with a mild right-side stride drop after station transitions.",
                    metrics: [
                        MetricResult(label: "Symmetry", value: "92%", status: .caution),
                        MetricResult(label: "Cadence", value: "174 spm", status: .strong),
                        MetricResult(label: "Right stride", value: "Short", status: .caution)
                    ],
                    alerts: [
                        RedFlagAlert(station: .running, title: "Right stride shorter", message: "Check hip extension after sled work; right stride shortens during the first 200 m.", severity: .low, timestamp: 486)
                    ]
                ),
                StationScore(
                    station: .lunges,
                    score: 76,
                    status: .caution,
                    primaryFeedback: "Knee contact is valid, but shin angle suggests quad dominance under fatigue. Shift load back into hips.",
                    metrics: [
                        MetricResult(label: "Knee contact", value: "91%", status: .strong),
                        MetricResult(label: "Glute/quad", value: "43/57", status: .caution),
                        MetricResult(label: "Stride", value: "Consistent", status: .strong)
                    ],
                    alerts: [
                        RedFlagAlert(station: .lunges, title: "Quad-dominant pattern", message: "Use a slightly longer stride and torso angle to shift load toward the hips.", severity: .medium, timestamp: 563)
                    ]
                )
            ]
        )
    }
}