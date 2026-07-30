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

    private let wallBallCounter = WallBallRepCounter()

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

        if station == .wallBalls {
            return wallBallScore(frames: frames)
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

    private func wallBallScore(frames: [PoseFrame]) -> StationScore {
        let result = wallBallCounter.evaluate(frames: frames)

        guard result.attempts > 0 else {
            return StationScore(
                station: .wallBalls,
                score: 0,
                status: .needsWork,
                primaryFeedback: "No wall-ball squats were detected. Keep hips, knees, and ankles in frame through the full squat and record again.",
                metrics: [
                    MetricResult(label: "Valid reps", value: "0", status: .needsWork),
                    MetricResult(label: "Frames analyzed", value: "\(frames.count)", status: .caution)
                ],
                alerts: []
            )
        }

        let accuracy = result.depthAccuracy
        let score = Int((accuracy * 100).rounded())
        let depthMisses = result.attempts - result.validReps

        var metrics: [MetricResult] = [
            MetricResult(label: "Valid reps", value: "\(result.validReps)", status: depthStatus(accuracy)),
            MetricResult(label: "Total squats", value: "\(result.attempts)", status: .raceReady),
            MetricResult(label: "Depth accuracy", value: "\(score)%", status: depthStatus(accuracy))
        ]
        if depthMisses > 0 {
            metrics.append(MetricResult(label: "Shallow reps", value: "\(depthMisses)", status: .caution))
        }

        var alerts: [RedFlagAlert] = []
        if depthMisses > 0 {
            alerts.append(
                RedFlagAlert(
                    station: .wallBalls,
                    title: "Squat depth misses",
                    message: "\(depthMisses) of \(result.attempts) squats did not reach hip-below-knee depth. Sink the hips lower before the throw.",
                    severity: accuracy < 0.6 ? .high : .medium,
                    timestamp: nil
                )
            )
        }

        return StationScore(
            station: .wallBalls,
            score: score,
            status: depthStatus(accuracy),
            primaryFeedback: "\(result.validReps) of \(result.attempts) squats reached legal depth (hip below knee). "
                + "Depth is judged from tracked joints and is most reliable with the full body in a side or front view.",
            metrics: metrics,
            alerts: alerts
        )
    }

    private func depthStatus(_ accuracy: Double) -> StationStatus {
        switch accuracy {
        case 0.9...: .strong
        case 0.75..<0.9: .raceReady
        case 0.5..<0.75: .caution
        default: .needsWork
        }
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
