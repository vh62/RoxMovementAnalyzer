import Foundation

/// Turns the pose frames captured during a live recording into a scorecard for the recorded station.
///
/// This intentionally reports only signals we can measure directly (tracking coverage, session
/// length, joint angles). The score reflects how well the body was tracked, not a validated HYROX
/// technique grade — that requires per-station rules tuned against real footage.
protocol LiveSessionAnalyzing {
    func analyze(station: HyroxStation, frames: [PoseFrame]) -> WorkoutScorecard
}

struct PoseSessionAnalyzer: LiveSessionAnalyzing {
    func analyze(station: HyroxStation, frames: [PoseFrame]) -> WorkoutScorecard {
        WorkoutScorecard(
            athleteName: "Live Session",
            sessionName: "\(station.rawValue) — Live Analysis",
            sessionDate: Date(),
            stations: [stationScore(station: station, frames: frames)]
        )
    }

    private func stationScore(station: HyroxStation, frames: [PoseFrame]) -> StationScore {
        let frameCount = frames.count
        guard frameCount > 0 else {
            return StationScore(
                station: station,
                score: 0,
                status: .needsWork,
                primaryFeedback: "No pose was tracked during this recording. Keep your full body in frame and record again.",
                metrics: [MetricResult(label: "Frames analyzed", value: "0", status: .needsWork)],
                alerts: []
            )
        }

        let coverage = fullBodyCoverage(frames)
        let coverageScore = Int((coverage * 100).rounded())
        let durationSeconds = sessionDuration(frames)
        let hingeAngles = frames.compactMap { $0.hipHingeAngle() }

        var metrics: [MetricResult] = [
            MetricResult(label: "Frames analyzed", value: "\(frameCount)", status: .strong),
            MetricResult(
                label: "Full-body coverage",
                value: "\(coverageScore)%",
                status: coverageStatus(coverage)
            )
        ]

        if durationSeconds > 0 {
            metrics.append(
                MetricResult(label: "Session length", value: String(format: "%.1f s", durationSeconds), status: .raceReady)
            )
        }

        if let deepestHinge = hingeAngles.min() {
            metrics.append(
                MetricResult(label: "Deepest hinge", value: "\(Int(deepestHinge.rounded()))°", status: .raceReady)
            )
        }

        return StationScore(
            station: station,
            score: coverageScore,
            status: coverageStatus(coverage),
            primaryFeedback: "Tracked \(frameCount) frames with the full body visible \(coverageScore)% of the time. "
                + "The score reflects tracking coverage for this session, not a validated technique grade.",
            metrics: metrics,
            alerts: []
        )
    }

    /// Fraction of captured frames in which the core lower- and upper-body joints were all confidently tracked.
    private func fullBodyCoverage(_ frames: [PoseFrame]) -> Double {
        guard !frames.isEmpty else { return 0 }
        let fullBodyFrames = frames.filter {
            $0.areVisible(
                .leftShoulder, .rightShoulder,
                .leftHip, .rightHip,
                .leftKnee, .rightKnee,
                .leftAnkle, .rightAnkle
            )
        }
        return Double(fullBodyFrames.count) / Double(frames.count)
    }

    private func sessionDuration(_ frames: [PoseFrame]) -> Double {
        guard let first = frames.first?.timestampInMilliseconds,
              let last = frames.last?.timestampInMilliseconds,
              last > first else { return 0 }
        return Double(last - first) / 1000
    }

    private func coverageStatus(_ coverage: Double) -> StationStatus {
        switch coverage {
        case 0.85...: .strong
        case 0.6..<0.85: .raceReady
        case 0.3..<0.6: .caution
        default: .needsWork
        }
    }
}
