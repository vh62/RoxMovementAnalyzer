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
        case .skiErg: return skiErgScore(frames: frames)
        case .burpeeBroadJumps: return burpeeScore(frames: frames)
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

    /// Pull technique for a SkiErg piece.
    ///
    /// Scored the way rowing is rather than the way wall balls is: the machine logs the metres whatever
    /// the pull looked like, so nothing here voids a pull and the score is simply the share that raised
    /// no fault, against thresholds that have not yet been calibrated on real footage.
    private func skiErgScore(frames: [PoseFrame]) -> StationScore {
        let pulls = SkiPullAnalyzer.analyze(frames: frames)

        guard !pulls.isEmpty else {
            return StationScore(
                station: .skiErg,
                score: 0,
                status: .needsWork,
                primaryFeedback: "No SkiErg pulls were detected. Film from the side with the whole "
                    + "athlete in frame — including the hands at full reach overhead — then record "
                    + "again.",
                metrics: [
                    MetricResult(label: "Pulls", value: "0", status: .needsWork),
                    MetricResult(label: "Frames analyzed", value: "\(frames.count)", status: .caution)
                ],
                alerts: []
            )
        }

        let clean = pulls.filter(\.faults.isEmpty).count
        let accuracy = Double(clean) / Double(pulls.count)
        let score = Int((accuracy * 100).rounded())

        var metrics: [MetricResult] = [
            MetricResult(label: "Pulls", value: "\(pulls.count)", status: .raceReady),
            MetricResult(label: "Clean pulls", value: "\(clean)", status: depthStatus(accuracy))
        ]

        if let rate = mean(pulls.compactMap(\.pullRateSPM)) {
            metrics.append(
                MetricResult(label: "Pull rate", value: String(format: "%.0f/min", rate), status: .raceReady)
            )
        }

        // Reported, never judged. Ski rhythm is the athlete's to choose and varies with where they
        // are in the piece, so this carries no status of its own.
        if let ratio = mean(pulls.compactMap(\.recoveryRatio)) {
            metrics.append(
                MetricResult(
                    label: "Drive:recovery",
                    value: String(format: "1:%.1f", ratio),
                    status: .raceReady
                )
            )
        }

        // Say why rather than silently omitting the measurements a front-on camera cannot make.
        if let viewpoint = pulls.last?.viewpoint, !viewpoint.supportsReachMeasurement {
            metrics.append(MetricResult(label: "Hip hinge", value: "Needs side view", status: .caution))
        } else if let lean = mean(pulls.compactMap(\.finishForwardLean)) {
            let upright = pulls.filter {
                $0.hasFault(.noHipHinge) || $0.hasFault(.squattingNotHinging)
            }.count
            metrics.append(
                MetricResult(
                    label: "Hip hinge",
                    value: "\(Int(lean.rounded()))°",
                    status: upright == 0 ? .strong : (upright > pulls.count / 3 ? .needsWork : .caution)
                )
            )
        }

        // The force curve, in the two terms a coach would use: where the power landed, and whether the
        // athlete was on the handles at full reach. Both are shares of the pull's own peak, never
        // newtons — see `SkiThresholds`' force-curve note.
        if let peak = mean(pulls.compactMap(\.peakAtDriveFraction)) {
            let late = pulls.filter { $0.hasFault(.backLoadedDrive) || $0.hasFault(.disconnectedDrive) }.count
            metrics.append(
                MetricResult(
                    label: "Power peak",
                    value: "\(Int((peak * 100).rounded()))% in",
                    status: late == 0 ? .strong : (late > pulls.count / 3 ? .needsWork : .caution)
                )
            )
        }

        // Shown, never judged: on a single-peaked curve this is "Power peak" seen from the other end,
        // so giving it a status of its own would grade the same thing twice.
        if let connection = mean(pulls.compactMap(\.catchConnection)) {
            metrics.append(
                MetricResult(
                    label: "Top-end load",
                    value: "\(Int((connection * 100).rounded()))%",
                    status: .raceReady
                )
            )
        }

        if pulls.contains(where: { !$0.handsTracked }) {
            metrics.append(MetricResult(label: "Hands in frame", value: "Partial", status: .caution))
        }

        return StationScore(
            station: .skiErg,
            score: score,
            status: depthStatus(accuracy),
            primaryFeedback: "\(clean) of \(pulls.count) pulls were clean. Every pull counts on the "
                + "ski — this scores the sequencing and range of the pull, not whether it was legal, "
                + "and the thresholds behind it are starting estimates rather than calibrated values.",
            metrics: metrics,
            alerts: alerts(
                for: StationAnalysis.skiErg(pulls).countedMovements,
                station: .skiErg,
                kindOrder: SkiFault.Kind.allCases.map(\.rawValue),
                noun: "pulls"
            )
        )
    }

    /// Rule compliance over a set of burpee broad jumps.
    ///
    /// Scored the way wall balls is rather than the way the ergs are: §8.4 gives this station a
    /// judging standard, so a rep either counts or it does not, and the score is the share that
    /// counted. Unlike wall balls there are four ways to fail rather than one, so the headline number
    /// is valid reps over attempts and the alerts say which rule cost them.
    private func burpeeScore(frames: [PoseFrame]) -> StationScore {
        let reps = BurpeeRepAnalyzer.analyze(frames: frames)

        guard !reps.isEmpty else {
            return StationScore(
                station: .burpeeBroadJumps,
                score: 0,
                status: .needsWork,
                primaryFeedback: "No burpee broad jumps were detected. Film from the side, square to "
                    + "the direction you travel, with your hands and feet in frame on the floor. "
                    + "Expect to capture three or four reps before you jump out of shot — this is a "
                    + "technique check on a few reps, not a counter for the full 80 m.",
                metrics: [
                    MetricResult(label: "Valid reps", value: "0", status: .needsWork),
                    MetricResult(label: "Frames analyzed", value: "\(frames.count)", status: .caution)
                ],
                alerts: []
            )
        }

        let valid = reps.filter(\.isValid).count
        let accuracy = Double(valid) / Double(reps.count)
        let score = Int((accuracy * 100).rounded())

        var metrics: [MetricResult] = [
            MetricResult(label: "Valid reps", value: "\(valid)", status: depthStatus(accuracy)),
            MetricResult(label: "Total reps", value: "\(reps.count)", status: .raceReady),
            MetricResult(label: "Rule compliance", value: "\(score)%", status: depthStatus(accuracy))
        ]

        if let rate = mean(reps.compactMap(\.repRate)) {
            metrics.append(
                MetricResult(label: "Rep rate", value: String(format: "%.0f/min", rate), status: .raceReady)
            )
        }

        // Reported, never judged. Rule 9 leaves the length of each broad jump to the racer, so this
        // carries no status of its own — but it is the number that decides how many reps 80 m costs,
        // which makes it the most useful thing on the card that is not a rule.
        if let distance = mean(reps.compactMap(\.jumpDistance)) {
            metrics.append(
                MetricResult(
                    label: "Jump distance",
                    value: String(format: "%.1f torso lengths", distance),
                    status: .raceReady
                )
            )
        }

        // Say why rather than silently omitting the rules a front-on camera cannot judge.
        if let viewpoint = reps.last?.viewpoint, !viewpoint.supportsReachMeasurement {
            metrics.append(
                MetricResult(label: "Hand and foot rules", value: "Needs side view", status: .caution)
            )
        } else {
            let corridorBreaches = reps.filter {
                $0.hasFault(.feetPastFingertips) || $0.hasFault(.handsTooFarForward)
            }.count
            metrics.append(
                MetricResult(
                    label: "Hand and foot rules",
                    value: "\(reps.count - corridorBreaches) of \(reps.count)",
                    status: corridorBreaches == 0
                        ? .strong
                        : (corridorBreaches > reps.count / 3 ? .needsWork : .caution)
                )
            )
        }

        let chestMisses = reps.filter { $0.hasFault(.chestNotDown) }.count
        metrics.append(
            MetricResult(
                label: "Chest contact",
                value: "\(reps.count - chestMisses) of \(reps.count)",
                status: chestMisses == 0 ? .strong : (chestMisses > reps.count / 3 ? .needsWork : .caution)
            )
        )

        return StationScore(
            station: .burpeeBroadJumps,
            score: score,
            status: depthStatus(accuracy),
            primaryFeedback: "\(valid) of \(reps.count) burpee broad jumps met every rule checked. "
                + "Judged against §8.4 of the rulebook — the hand and foot placement rules and "
                + "chest contact. The 5 cm foot-stagger tolerance is not checked: it is finer than "
                + "pose tracking can resolve.",
            metrics: metrics,
            alerts: alerts(
                for: StationAnalysis.burpees(reps).countedMovements,
                station: .burpeeBroadJumps,
                kindOrder: BurpeeFault.Kind.allCases.map(\.rawValue),
                noun: "reps"
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
    /// Shared by every analysed station: `kindOrder` supplies the station's own priority so the alerts
    /// come out in the order that station would coach them.
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

    /// Banding shared by wall-ball depth accuracy and both ergs' clean-movement share.
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
