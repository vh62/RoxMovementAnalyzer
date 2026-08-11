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

        switch station {
        case .wallBalls: return wallBallScore(frames: frames)
        case .rowing: return rowingScore(frames: frames)
        default: break
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
        let reps = WallBallRepAnalyzer.analyze(frames: frames)

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

        metrics.append(contentsOf: efficiencyMetrics(for: reps))

        // Depth used to need its own alert here. It is a fault now, so the shared aggregation covers
        // it along with the rest — reporting it twice would just say the same thing in two places.
        let alerts = alerts(
            for: StationAnalysis.wallBalls(reps).countedMovements,
            station: .wallBalls,
            kindOrder: WallBallFault.Kind.allCases.map(\.rawValue),
            noun: "reps"
        )

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

    /// Stroke technique for a RowErg piece.
    ///
    /// Unlike wall balls this score is **not** a rule check. The erg logs the metres whatever the
    /// stroke looked like, so there is no equivalent of a no-rep and nothing here voids a stroke —
    /// the score is the share of strokes that raised no fault, against thresholds that have not yet
    /// been calibrated on real footage.
    private func rowingScore(frames: [PoseFrame]) -> StationScore {
        let strokes = RowStrokeAnalyzer.analyze(frames: frames)

        guard !strokes.isEmpty else {
            return StationScore(
                station: .rowing,
                score: 0,
                status: .needsWork,
                primaryFeedback: "No rowing strokes were detected. Film from the side with the hips, "
                    + "knees, and ankles in frame for the whole stroke, then record again.",
                metrics: [
                    MetricResult(label: "Strokes", value: "0", status: .needsWork),
                    MetricResult(label: "Frames analyzed", value: "\(frames.count)", status: .caution)
                ],
                alerts: []
            )
        }

        let clean = strokes.filter(\.faults.isEmpty).count
        let accuracy = Double(clean) / Double(strokes.count)
        let score = Int((accuracy * 100).rounded())

        var metrics: [MetricResult] = [
            MetricResult(label: "Strokes", value: "\(strokes.count)", status: .raceReady),
            MetricResult(label: "Clean strokes", value: "\(clean)", status: depthStatus(accuracy))
        ]

        if let rate = mean(strokes.compactMap(\.strokeRateSPM)) {
            metrics.append(
                MetricResult(label: "Stroke rate", value: String(format: "%.0f spm", rate), status: .raceReady)
            )
        }

        if let ratio = mean(strokes.compactMap(\.recoveryRatio)) {
            let rushed = strokes.filter { $0.hasFault(.rushingTheRecovery) }.count
            metrics.append(
                MetricResult(
                    label: "Drive:recovery",
                    value: String(format: "1:%.1f", ratio),
                    status: rushed == 0 ? .strong : (rushed > strokes.count / 3 ? .needsWork : .caution)
                )
            )
        }

        if let catchAngle = mean(strokes.map(\.catchKneeAngle)) {
            let short = strokes.filter { $0.hasFault(.incompleteCatch) }.count
            metrics.append(
                MetricResult(
                    label: "Catch angle",
                    value: "\(Int(catchAngle.rounded()))°",
                    status: short == 0 ? .strong : .caution
                )
            )
        }

        // Say why rather than silently omitting the handle numbers.
        if let viewpoint = strokes.last?.viewpoint, !viewpoint.supportsReachMeasurement {
            metrics.append(
                MetricResult(label: "Handle travel", value: "Needs side view", status: .caution)
            )
        } else if let slide = mean(strokes.compactMap(\.slideRatio)) {
            let shooting = strokes.filter { $0.hasFault(.shootingTheSlide) }.count
            metrics.append(
                MetricResult(
                    label: "Handle travel",
                    value: String(format: "%.0f%% of seat", slide * 100),
                    status: shooting == 0 ? .strong : .caution
                )
            )
        }

        if strokes.contains(where: { !$0.handsTracked }) {
            metrics.append(MetricResult(label: "Hands in frame", value: "Partial", status: .caution))
        }

        return StationScore(
            station: .rowing,
            score: score,
            status: depthStatus(accuracy),
            primaryFeedback: "\(clean) of \(strokes.count) strokes were clean. Every stroke counts on "
                + "the erg — this scores the sequencing and range of the stroke, not whether it was "
                + "legal, and the thresholds behind it are starting estimates rather than calibrated "
                + "values.",
            metrics: metrics,
            alerts: alerts(
                for: StationAnalysis.rowing(strokes).countedMovements,
                station: .rowing,
                kindOrder: RowingFault.Kind.allCases.map(\.rawValue),
                noun: "strokes"
            )
        )
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// One alert per fault kind, pointing at the first movement where it happened so the scorecard
    /// can jump the replay to that moment.
    ///
    /// Shared by both analysed stations: `kindOrder` supplies the station's own priority so the
    /// alerts come out in the order that station would coach them.
    private func alerts(
        for movements: [CountedMovement],
        station: HyroxStation,
        kindOrder: [String],
        noun: String
    ) -> [RedFlagAlert] {
        kindOrder.compactMap { kind in
            let offending = movements.filter { $0.faults.contains { $0.kindIdentifier == kind } }
            guard let first = offending.first,
                  let fault = first.faults.first(where: { $0.kindIdentifier == kind }) else { return nil }

            return RedFlagAlert(
                station: station,
                title: fault.title,
                message: "\(offending.count) of \(movements.count) \(noun). \(fault.coachingDetail)",
                severity: offending.count > movements.count / 3 ? fault.severity : .low,
                timestamp: first.calloutSeconds
            )
        }
    }

    /// Release-timing and catch-position readouts, alongside the depth numbers.
    private func efficiencyMetrics(for reps: [WallBallRep]) -> [MetricResult] {
        var metrics: [MetricResult] = []

        let offsets = reps.compactMap(\.releaseOffset)
        if !offsets.isEmpty {
            let average = offsets.reduce(0, +) / Double(offsets.count)
            let earlyCount = reps.filter { $0.hasFault(.earlyRelease) }.count
            let lateCount = reps.filter { $0.hasFault(.lateRelease) }.count
            let offCount = earlyCount + lateCount

            metrics.append(
                MetricResult(
                    label: "Release timing",
                    value: String(format: "%+.0f ms", average * 1000),
                    status: offCount == 0 ? .strong : (offCount > reps.count / 3 ? .needsWork : .caution)
                )
            )
        }

        let reaches = reps.compactMap(\.catchReach)
        if !reaches.isEmpty {
            let average = reaches.reduce(0, +) / Double(reaches.count)
            let farCount = reps.filter { $0.hasFault(.catchTooFarForward) }.count

            metrics.append(
                MetricResult(
                    label: "Catch distance",
                    value: String(format: "%.2f torso", average),
                    status: farCount == 0 ? .strong : (farCount > reps.count / 3 ? .needsWork : .caution)
                )
            )
        } else if let viewpoint = reps.last?.viewpoint, !viewpoint.supportsReachMeasurement {
            // Say why rather than silently omitting it.
            metrics.append(
                MetricResult(label: "Catch distance", value: "Needs side view", status: .caution)
            )
        }

        if reps.contains(where: { !$0.handsTracked }) {
            metrics.append(
                MetricResult(label: "Hands in frame", value: "Partial", status: .caution)
            )
        }

        return metrics
    }

    /// Banding shared by wall-ball depth accuracy and the rowing clean-stroke share.
    private func depthStatus(_ accuracy: Double) -> StationStatus {
        switch accuracy {
        case 0.9...: .strong
        case 0.75..<0.9: .raceReady
        case 0.5..<0.75: .caution
        default: .needsWork
        }
    }

    /// Fraction of captured frames in which the whole athlete was tracked.
    ///
    /// Defers to `PoseFrame.hasFullBody` rather than repeating the joint list, so this metric
    /// cannot drift from the rule the overlay uses to decide whether to draw.
    private func fullBodyCoverage(_ frames: [PoseFrame]) -> Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter(\.hasFullBody).count) / Double(frames.count)
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
