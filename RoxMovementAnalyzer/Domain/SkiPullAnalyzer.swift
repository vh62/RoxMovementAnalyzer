import Foundation

/// A single SkiErg pull, segmented into phases with the measurements each fault depends on.
///
/// A pull runs **catch to catch** — hands highest to hands highest — which is how a coach counts them
/// and the only definition that gives the drive-to-recovery ratio a denominator. Member names
/// deliberately match `RowStroke` and `WallBallRep` so a shared `MovementRep` protocol can be
/// introduced later with no edits here.
struct SkiPull: Equatable, Identifiable {
    var id: Int { index }

    let index: Int
    /// Seconds from the first analysed frame. This is the catch that opened the pull.
    let startSeconds: Double
    let finishSeconds: Double
    /// The next catch, which closes this pull and opens the following one.
    let endSeconds: Double

    /// Shoulder sweep angle at the catch, with the arms overhead. The larger of the two.
    let catchShoulderAngle: Double
    /// Shoulder sweep angle at the finish, with the hands past the hips.
    let finishShoulderAngle: Double

    /// Torso angle at the catch, positive leaning toward the machine. Near zero standing tall.
    let catchForwardLean: Double?
    /// Torso angle at the finish — the hinge, which is where the pull's power comes from.
    let finishForwardLean: Double?

    /// Peak hand speed over the drive, in scale units per second — the force proxy's peak. Nil when the
    /// wrists were not tracked throughout, or the scale had not settled.
    let peakHandSpeed: Double?
    /// Where that peak sat in the drive, 0 at the catch and 1 at the finish. A body-driven pull
    /// front-loads; a pull finished by the arms puts it late.
    ///
    /// Measured over the **detected** drive, which is slightly shorter than the athlete's: the catch is
    /// credited to the maximum of a smoothed signal and needs `shoulderReversalHysteresis` to confirm,
    /// so a near-stationary top is trimmed. Read this as "where the power landed within the moving part
    /// of the pull" — the verdict is stable across cadences, the raw figure drifts with them.
    let peakAtDriveFraction: Double?
    /// Mean hand speed over the opening quarter of the sweep ÷ the peak — how hard the athlete loaded
    /// the handles at full reach.
    let catchConnection: Double?
    /// Trough between two comparable peaks ÷ the smaller of them, when the drive came in two efforts.
    /// Nil when the drive was a single push, which is the healthy case.
    let midDriveDip: Double?

    /// The hand path over the drive, tinted by how hard the athlete was pulling as it passed through —
    /// the force curve laid onto the athlete's own range of motion, for the replay overlay to draw.
    ///
    /// Empty under exactly the conditions that nil the readings above. A trail without a verdict, or a
    /// verdict without a trail, would be two sources of truth about the same pull.
    let powerTrail: [PowerSample]

    /// Degrees of forward torso swing over the drive.
    let leanRange: Double?
    /// Degrees of knee flexion over the drive.
    let kneeFlexionRange: Double?
    /// Torso swing ÷ knee flexion. Above 1 is a hinge-led pull; well below it, the legs did the work.
    let hingeToKneeRatio: Double?

    /// The scale reference sampled on this pull, carried so a session's spread can be inspected the
    /// way `RowStroke.torsoScaleSample` is.
    let torsoScaleSample: Double?

    let viewpoint: CameraViewpoint
    let facing: Facing?
    /// False when the wrists were not tracked throughout the drive, so hand-position faults could not
    /// be measured. On a SkiErg this is the common case rather than an edge one: the catch puts the
    /// hands above the head, which is the first thing a tight frame loses.
    let handsTracked: Bool

    let faults: [SkiFault]

    var driveSeconds: Double { finishSeconds - startSeconds }
    var recoverySeconds: Double { endSeconds - finishSeconds }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// Recovery ÷ drive.
    var recoveryRatio: Double? {
        driveSeconds > 0 ? recoverySeconds / driveSeconds : nil
    }

    /// Pulls per minute. A metric, never a fault: the right rate depends on the athlete and where they
    /// are in the piece, whereas an arms-first pull is a fault at any rate.
    var pullRateSPM: Double? {
        durationSeconds > 0 ? 60 / durationSeconds : nil
    }

    func hasFault(_ kind: SkiFault.Kind) -> Bool {
        faults.contains { $0.kind == kind }
    }

    /// One point on the hand path, with how hard the athlete was pulling as it passed through.
    ///
    /// Held in **normalized image coordinates** — the space `PoseLandmark.x/y` live in — rather than
    /// the ankle-anchored scale units the force proxy measures in. Measurement wants a frame of
    /// reference immune to the phone drifting; drawing wants to land on the video. Both come off the
    /// same wrist centre, so the overlay draws the point that was actually measured.
    ///
    /// A struct rather than a tuple: `SkiPull` is `Equatable` and `StationAnalysis` carries
    /// `[SkiPull]`, so tuple members would break synthesis.
    struct PowerSample: Equatable {
        let x: Double
        let y: Double
        /// Hand speed here ÷ this pull's peak, 0...1.
        ///
        /// Normalised per pull, so **every pull is bright somewhere**. This shows the shape of a pull,
        /// never how hard it was — the same in-pull-ratio discipline every other force-curve reading
        /// follows, and the reason none of them claims to be newtons.
        let intensity: Double
    }
}

/// Segments SkiErg pulls and measures the technique faults in each.
///
/// Stateful and incremental (`process(_:)` per frame) so live analysis and post-session analysis run
/// identical logic, exactly as `WallBallRepAnalyzer` and `RowStrokeAnalyzer` do.
///
/// **Segmentation runs on the near-side shoulder sweep angle** — hip-shoulder-elbow. The catch is its
/// maximum, with the arms straight overhead, and the finish its minimum, with the hands driven past the
/// hips: a ~130° sweep, comparable to rowing's knee angle, and scale-free and translation-free for the
/// same reason, so it needs no length reference and survives a handheld phone drifting.
///
/// The two obvious alternatives are both worse, and rejecting them is what fixes the design:
///
/// - **Not hand height.** On an overhead reach the wrists are the first landmark to leave the picture
///   — that is precisely the failure `LiveFeedbackGenerating.framingCue` exists to warn about. Putting
///   segmentation on the wrists would make a badly framed session count nothing at all instead of
///   counting pulls and suppressing the two faults that need the hands. The shoulder angle needs the
///   elbow, which sits a forearm lower and stays in frame.
/// - **Not the hip hinge.** An arms-only pull is this station's headline fault. If the hinge carried
///   segmentation, that pull would go *uncounted* rather than *flagged* — the analyzer would fall
///   silent on the very thing it exists to catch. (Rowing can safely segment on the knee because the
///   legs are the machine's constraint; here the arms are.)
///
/// The near side is used rather than a two-sided maximum: side-on, MediaPipe estimates the occluded far
/// arm rather than tracking it, and an estimate straighter than reality would misplace the sweep.
///
/// **Pulls run catch to catch, so N confirmed catches yield N−1 pulls.** The leading and trailing
/// partials are discarded because their drive or recovery time is unknown, and half the fault set is
/// unmeasurable without it — expect `pullsSoFar` to lead `completedPulls.count` by one, as rowing's
/// tally does.
struct SkiPullAnalyzer {
    var thresholds: SkiThresholds = .default

    private(set) var completedPulls: [SkiPull] = []
    /// Catches confirmed so far — the live-display counterpart of `RowStrokeAnalyzer.strokesSoFar`.
    /// Leads `completedPulls.count` by one, because a pull is not complete until the *next* catch.
    private(set) var pullsSoFar = 0

    init(thresholds: SkiThresholds = .default) {
        self.thresholds = thresholds
        self.scale = ScaleReference(
            minimumSamples: thresholds.minScaleSamples,
            outlierTolerance: thresholds.scaleOutlierTolerance
        )
        self.sideVote = NearSideVote(voteFrames: thresholds.sideVoteFrames)
    }

    // MARK: - Frame intake

    mutating func process(_ frame: PoseFrame) {
        if anchorMilliseconds == nil { anchorMilliseconds = frame.timestampInMilliseconds }
        let seconds = Double(frame.timestampInMilliseconds - (anchorMilliseconds ?? 0)) / 1000

        observeSession(frame)

        guard let side = nearSide,
              let rawShoulderAngle = frame.shoulderAngle(side) else { return }

        // A gap long enough to distort a phase must not be papered over: the sequence and rhythm
        // faults are timing-based, so a silent gap manufactures faults.
        if let last = lastSampleSeconds, seconds - last > thresholds.trackingGapSeconds {
            resetTracking()
        }
        lastSampleSeconds = seconds

        // A pull this long is a rest between pieces, not a pull.
        if let open = openPull, seconds - open.catchSeconds > thresholds.maxPullSeconds {
            resetTracking()
        }

        shoulderWindow.append(rawShoulderAngle)
        if shoulderWindow.count > max(thresholds.shoulderSmoothingWindow, 1) {
            shoulderWindow.removeFirst()
        }
        guard let smoothed = smoothedShoulderAngle else { return }

        recordSample(from: frame, side: side, shoulderAngle: smoothed, at: seconds)
        advanceStateMachine(shoulderAngle: smoothed, at: seconds)
    }

    /// Closes out the analyzer. The pull still in progress is deliberately **not** emitted — its
    /// recovery has not happened yet, so its ratio and finish measurements do not exist.
    mutating func finish() {
        openPull = nil
        samples.removeAll(keepingCapacity: false)
    }

    /// One-shot analysis over a complete recording.
    static func analyze(
        frames: [PoseFrame],
        thresholds: SkiThresholds = .default
    ) -> [SkiPull] {
        var analyzer = SkiPullAnalyzer(thresholds: thresholds)
        for frame in frames { analyzer.process(frame) }
        analyzer.finish()
        return analyzer.completedPulls
    }

    // MARK: - Session-level observation

    /// Facing, near side, scale and viewpoint are all session properties rather than per-frame ones,
    /// and all four are deliberately sticky. A value that flipped mid-pull would mirror or rescale one
    /// sample's measurements and read as a violent handle reversal.
    private mutating func observeSession(_ frame: PoseFrame) {
        if latchedFacing == nil {
            facingTally += frame.standingFacingVote
            if abs(facingTally) >= thresholds.facingConfidenceVotes {
                latchedFacing = facingTally > 0 ? .right : .left
            }
        }

        sideVote.observe(frame)

        if let torso = frame.sagittalTorsoLength { scale.observe(torso) }

        let viewpoint = frame.viewpoint(thresholds: thresholds.viewpoint)
        if viewpoint != .unknown { viewpointTally[viewpoint, default: 0] += 1 }
    }

    private var nearSide: BodySide? { sideVote.side }

    /// The side the overlay should draw, or nil to draw both.
    ///
    /// Stricter than `nearSide` in two ways, because drawing may decline where measuring may not: the
    /// vote must have won by a margin, and the camera must actually be beside the athlete. Gated on
    /// the same `supportsReachMeasurement` the horizontal measurements use, so the skeleton and the
    /// numbers agree about whether this is a profile shot.
    var profileSide: BodySide? {
        guard modalViewpoint.supportsReachMeasurement else { return nil }
        return sideVote.confidentSide
    }

    /// The modal viewpoint over the session, not the most recent one: the overhead reach rolls the
    /// shoulders forward once per pull, so "last" samples a random phase of that oscillation.
    private var modalViewpoint: CameraViewpoint {
        viewpointTally.max { $0.value < $1.value }?.key ?? .unknown
    }

    private var smoothedShoulderAngle: Double? {
        guard !shoulderWindow.isEmpty else { return nil }
        return shoulderWindow.reduce(0, +) / Double(shoulderWindow.count)
    }

    private mutating func recordSample(
        from frame: PoseFrame,
        side: BodySide,
        shoulderAngle: Double,
        at seconds: Double
    ) {
        let facing = latchedFacing
        let scaleValue = scale.value

        samples.append(
            PullSample(
                seconds: seconds,
                shoulderAngle: shoulderAngle,
                forwardLean: facing.flatMap { frame.forwardTorsoLean(facing: $0) },
                kneeAngle: frame.kneeAngle(side),
                handPoint: facing.flatMap { facing in
                    scaleValue.flatMap { frame.handOffsetFromFeet(facing: facing, scale: $0) }
                },
                handImagePoint: frame.visibleCenter(.leftWrist, .rightWrist),
                wristsVisible: frame.hasTrackedHands,
                torsoLength: frame.sagittalTorsoLength
            )
        )

        // Bounded: anything older than the longest pull we would ever emit cannot belong to the pull
        // in progress.
        let cutoff = seconds - (thresholds.maxPullSeconds + 1)
        while let first = samples.first, first.seconds < cutoff {
            samples.removeFirst()
        }
    }

    private mutating func resetTracking() {
        openPull = nil
        samples.removeAll(keepingCapacity: true)
        shoulderWindow.removeAll(keepingCapacity: true)
        phase = .unknown
        risingExtreme = nil
        fallingExtreme = nil
        confirmations = 0
    }

    // MARK: - Segmentation

    /// Locates the catch and the finish as reversals in the shoulder angle, crediting each event to
    /// where the extremum actually occurred rather than to where it was confirmed — the same idiom as
    /// `RowStrokeAnalyzer.advanceStateMachine` and `WallBallRepAnalyzer.detectRelease`.
    ///
    /// The roles of the extremes are inverted relative to rowing: there the drive *extends* the knee,
    /// here the drive *closes* the shoulder, so the drive hunts a minimum and the recovery a maximum.
    private mutating func advanceStateMachine(shoulderAngle: Double, at seconds: Double) {
        switch phase {
        case .unknown:
            seedPhase(shoulderAngle: shoulderAngle, at: seconds)

        case .drive:
            // Arms sweeping down: looking for the finish, the minimum.
            guard var extreme = fallingExtreme else {
                fallingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                return
            }
            if shoulderAngle < extreme.value {
                extreme = Extreme(value: shoulderAngle, seconds: seconds)
                fallingExtreme = extreme
                confirmations = 0
            } else if shoulderAngle > extreme.value + thresholds.shoulderReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordFinish(at: extreme.seconds, shoulderAngle: extreme.value)
                    phase = .recovery
                    risingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }

        case .recovery:
            // Arms rising back overhead: looking for the catch, the maximum.
            guard var extreme = risingExtreme else {
                risingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                return
            }
            if shoulderAngle > extreme.value {
                extreme = Extreme(value: shoulderAngle, seconds: seconds)
                risingExtreme = extreme
                confirmations = 0
            } else if shoulderAngle < extreme.value - thresholds.shoulderReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordCatch(at: extreme.seconds, shoulderAngle: extreme.value)
                    phase = .drive
                    fallingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }
        }
    }

    /// Until a reversal has been seen there is no way to know whether the athlete is driving or
    /// recovering, so both extremes are tracked and whichever reverses first decides.
    private mutating func seedPhase(shoulderAngle: Double, at seconds: Double) {
        if risingExtreme == nil || shoulderAngle > risingExtreme!.value {
            risingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
        }
        if fallingExtreme == nil || shoulderAngle < fallingExtreme!.value {
            fallingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
        }

        guard let rising = risingExtreme, let falling = fallingExtreme else { return }

        if shoulderAngle < rising.value - thresholds.shoulderReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                recordCatch(at: rising.seconds, shoulderAngle: rising.value)
                phase = .drive
                fallingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else if shoulderAngle > falling.value + thresholds.shoulderReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                // No pull is open yet, so this finish only tells us which phase we are in.
                phase = .recovery
                risingExtreme = Extreme(value: shoulderAngle, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else {
            seedConfirmations = 0
        }
    }

    private mutating func recordCatch(at seconds: Double, shoulderAngle: Double) {
        // This catch closes the pull the previous one opened.
        closePull(endSeconds: seconds)

        pullsSoFar += 1
        openPull = OpenPull(catchSeconds: seconds, catchShoulderAngle: shoulderAngle)
    }

    private mutating func recordFinish(at seconds: Double, shoulderAngle: Double) {
        guard var open = openPull else { return }
        open.finishSeconds = seconds
        open.finishShoulderAngle = shoulderAngle
        openPull = open
    }

    // MARK: - Pull close

    private mutating func closePull(endSeconds: Double) {
        guard let open = openPull else { return }
        openPull = nil

        guard let finishSeconds = open.finishSeconds,
              let finishShoulderAngle = open.finishShoulderAngle else { return }

        let duration = endSeconds - open.catchSeconds
        guard duration >= thresholds.minPullSeconds,
              duration <= thresholds.maxPullSeconds,
              open.catchShoulderAngle - finishShoulderAngle >= thresholds.minPullShoulderRange
        else { return }

        let pullSamples = samples.filter {
            $0.seconds >= open.catchSeconds && $0.seconds <= endSeconds
        }
        let driveSamples = pullSamples.filter { $0.seconds <= finishSeconds }
        guard !driveSamples.isEmpty else { return }

        let pull = makePull(
            index: completedPulls.count,
            open: open,
            finishSeconds: finishSeconds,
            finishShoulderAngle: finishShoulderAngle,
            endSeconds: endSeconds,
            driveSamples: driveSamples
        )
        completedPulls.append(pull)
    }

    private func makePull(
        index: Int,
        open: OpenPull,
        finishSeconds: Double,
        finishShoulderAngle: Double,
        endSeconds: Double,
        driveSamples: [PullSample]
    ) -> SkiPull {
        let catchSample = driveSamples[0]

        let catchLean = driveSamples.first { $0.forwardLean != nil }?.forwardLean
        let finishLean = driveSamples.last { $0.forwardLean != nil }?.forwardLean
        let leanRange: Double? = {
            guard let catchLean, let finishLean else { return nil }
            return finishLean - catchLean
        }()

        let kneeFlexionRange: Double? = {
            guard let catchKnee = driveSamples.first(where: { $0.kneeAngle != nil })?.kneeAngle,
                  let deepestKnee = driveSamples.compactMap(\.kneeAngle).min() else { return nil }
            return catchKnee - deepestKnee
        }()

        let hingeToKneeRatio: Double? = {
            guard let leanRange, let kneeFlexionRange,
                  kneeFlexionRange >= thresholds.minKneeFlexionForRatio else { return nil }
            return leanRange / kneeFlexionRange
        }()

        let curve = forceCurve(
            driveSamples: driveSamples,
            catchShoulderAngle: open.catchShoulderAngle,
            finishShoulderAngle: finishShoulderAngle,
            driveSeconds: finishSeconds - open.catchSeconds
        )

        let pull = SkiPull(
            index: index,
            startSeconds: open.catchSeconds,
            finishSeconds: finishSeconds,
            endSeconds: endSeconds,
            catchShoulderAngle: open.catchShoulderAngle,
            finishShoulderAngle: finishShoulderAngle,
            catchForwardLean: catchLean,
            finishForwardLean: finishLean,
            peakHandSpeed: curve.peakSpeed,
            peakAtDriveFraction: curve.peakAtDriveFraction,
            catchConnection: curve.catchConnection,
            midDriveDip: curve.midDriveDip,
            powerTrail: curve.trail,
            leanRange: leanRange,
            kneeFlexionRange: kneeFlexionRange,
            hingeToKneeRatio: hingeToKneeRatio,
            torsoScaleSample: catchSample.torsoLength,
            viewpoint: modalViewpoint,
            facing: latchedFacing,
            handsTracked: driveSamples.allSatisfy(\.wristsVisible),
            faults: []
        )

        return pull.replacingFaults(faults(for: pull))
    }

    // MARK: - Force curve

    /// The hand-speed profile over the drive, and the three readings taken off it.
    ///
    /// **Speed stands in for force.** On an air-braked flywheel the drag term goes as the square of
    /// handle speed, so speed is monotonic in force and its peak is force's peak. The inertial term is
    /// deliberately not modelled: it needs hand *acceleration*, and differentiating MediaPipe wrists
    /// twice is mostly noise. Every reading below is a ratio taken inside one pull, so the proxy's
    /// unknown gain cancels and nothing here has to know the damper setting.
    ///
    /// Speeds come from a central difference — `|p[i+1] − p[i−1]| / (t[i+1] − t[i−1])` — which is both
    /// better centred and quieter than a forward difference, then a short moving average takes the
    /// remaining jitter off.
    private func forceCurve(
        driveSamples: [PullSample],
        catchShoulderAngle: Double,
        finishShoulderAngle: Double,
        driveSeconds: Double
    ) -> (
        peakSpeed: Double?,
        peakAtDriveFraction: Double?,
        catchConnection: Double?,
        midDriveDip: Double?,
        trail: [SkiPull.PowerSample]
    ) {
        let empty: (Double?, Double?, Double?, Double?, [SkiPull.PowerSample]) = (nil, nil, nil, nil, [])

        // One missing hand breaks the series rather than leaving a hole in it: a gap would read as a
        // sudden jump, which is exactly what a speed measurement would turn into a spike of force.
        let points = driveSamples.map(\.handPoint)
        guard driveSeconds > 0, points.allSatisfy({ $0 != nil }), points.count >= 5 else { return empty }
        let path = points.map { $0! }

        var speeds: [Double] = []
        var seconds: [Double] = []
        for i in 1..<(path.count - 1) {
            let span = driveSamples[i + 1].seconds - driveSamples[i - 1].seconds
            guard span > 0 else { continue }
            speeds.append(hypot(path[i + 1].x - path[i - 1].x, path[i + 1].y - path[i - 1].y) / span)
            seconds.append(driveSamples[i].seconds)
        }
        guard speeds.count >= 3 else { return empty }

        speeds = movingAverage(speeds, window: thresholds.handSpeedSmoothingWindow)

        guard let peakSpeed = speeds.max(), peakSpeed >= thresholds.minPeakHandSpeed,
              let peakIndex = speeds.firstIndex(of: peakSpeed) else { return empty }

        let start = driveSamples[0].seconds
        let peakAtDriveFraction = (seconds[peakIndex] - start) / driveSeconds

        // Loading at the top is judged over the opening share of the pull's own *sweep*, not of its
        // duration: the question is whether the athlete used the top of the range, and an athlete who
        // dawdles there would otherwise be given credit for the time they spent doing it.
        let sweep = catchShoulderAngle - finishShoulderAngle
        let catchConnection: Double? = {
            guard sweep > 0 else { return nil }
            let opening = zip(speeds.indices, speeds).filter { index, _ in
                let progress = (catchShoulderAngle - driveSamples[index + 1].shoulderAngle) / sweep
                return progress <= thresholds.catchConnectionSweepFraction
            }
            guard !opening.isEmpty else { return nil }
            return (opening.map(\.1).reduce(0, +) / Double(opening.count)) / peakSpeed
        }()

        // The trail is built from the same pass rather than recomputed: `speeds[i]` describes
        // `driveSamples[i + 1]`, so the tint and the point are the same measurement by construction.
        let trail: [SkiPull.PowerSample] = peakSpeed > 0
            ? zip(speeds.indices, speeds).compactMap { index, speed in
                guard let point = driveSamples[index + 1].handImagePoint else { return nil }
                return SkiPull.PowerSample(
                    x: point.x, y: point.y, intensity: min(max(speed / peakSpeed, 0), 1)
                )
            }
            : []

        return (
            peakSpeed,
            peakAtDriveFraction,
            catchConnection,
            midDriveDip(of: speeds, peak: peakSpeed),
            trail
        )
    }

    /// How deep the lull is between two comparable peaks, as a share of the smaller one — nil when the
    /// drive was a single push.
    ///
    /// Two peaks means the body and the arms took turns. Only peaks above
    /// `disconnectSecondPeakFraction` of the largest count, so a ripple in a single broad push is not
    /// mistaken for a second effort.
    private func midDriveDip(of speeds: [Double], peak: Double) -> Double? {
        let floor = peak * thresholds.disconnectSecondPeakFraction
        var peaks: [Int] = []
        for i in 1..<(speeds.count - 1) where speeds[i] >= floor
            && speeds[i] >= speeds[i - 1] && speeds[i] > speeds[i + 1] {
            peaks.append(i)
        }
        guard peaks.count >= 2, let first = peaks.first, let last = peaks.last, first < last else {
            return nil
        }

        let trough = speeds[first...last].min() ?? peak
        let smaller = min(speeds[first], speeds[last])
        guard smaller > 0 else { return nil }
        return trough / smaller
    }

    private func movingAverage(_ values: [Double], window: Int) -> [Double] {
        let span = max(window, 1)
        guard span > 1, values.count > span else { return values }

        return values.indices.map { index in
            let low = max(0, index - span / 2)
            let high = min(values.count - 1, index + span / 2)
            return values[low...high].reduce(0, +) / Double(high - low + 1)
        }
    }

    // MARK: - Faults

    /// Appended in coaching priority order, because `faults.first` is what the athlete is told.
    ///
    /// As with rowing there is no rule-versus-inefficiency distinction to respect — the SkiErg counts
    /// the metres either way — so this is purely which correction to make first: sequencing and joint
    /// substitution leak the most power and cause the rest, range of motion is free metres left on the
    /// table, and rhythm often resolves itself once the rest is fixed.
    private func faults(for pull: SkiPull) -> [SkiFault] {
        var faults: [SkiFault] = []

        // A front-on camera cannot see a hinge — the torso rotates in depth rather than across the
        // image — so a front-on athlete would read as never hinging. Suppress rather than invent.
        let sagittalMeasurable = pull.viewpoint.supportsReachMeasurement

        // One missing hinge, reported once. Both cases need a short finish lean; the ratio decides
        // which cue the athlete gets, and "stop squatting" wins when the knees over-contributed because
        // it says what to do instead. Reporting both would put the same finding in two places, the way
        // `RowStrokeAnalyzer` declines to report the high side of the slide ratio.
        if sagittalMeasurable, let lean = pull.finishForwardLean, lean < thresholds.minFinishLean {
            if let ratio = pull.hingeToKneeRatio, ratio < thresholds.minHingeToKneeRatio {
                faults.append(.squattingNotHinging(hingeToKneeRatio: ratio))
            } else {
                faults.append(.noHipHinge(lean: lean))
            }
        }

        // The force curve. Both go quiet together when the wrists were lost or the peak was too slow
        // to read — `forceCurve` nils the whole set rather than reporting some of it, because a
        // peak position taken from noise is worse than no peak position.
        if let fraction = pull.peakAtDriveFraction, fraction > thresholds.maxPeakDriveFraction {
            faults.append(.backLoadedDrive(peakAtDriveFraction: fraction))
        }

        if let dip = pull.midDriveDip, dip < thresholds.maxMidDriveDip {
            faults.append(.disconnectedDrive(dip: dip))
        }

        return faults
    }

    // MARK: - In-progress state

    private var anchorMilliseconds: Int?
    private var lastSampleSeconds: Double?

    private var scale: ScaleReference
    private var facingTally = 0
    private var latchedFacing: Facing?
    private var sideVote: NearSideVote
    private var viewpointTally: [CameraViewpoint: Int] = [:]

    private var shoulderWindow: [Double] = []
    private var samples: [PullSample] = []

    private var phase: Phase = .unknown
    private var risingExtreme: Extreme?
    private var fallingExtreme: Extreme?
    private var confirmations = 0
    private var seedConfirmations = 0
    private var openPull: OpenPull?

    private enum Phase {
        case unknown
        case drive
        case recovery
    }

    private struct Extreme {
        let value: Double
        let seconds: Double
    }

    /// The in-flight pull's derived scalars.
    ///
    /// Buffered rather than streamed for the reason `RowStrokeAnalyzer.StrokeSample` sets out: almost
    /// every measurement here is relative to the pull's own range at *both* ends, which is not known
    /// until the pull closes. Bounded by `maxPullSeconds`, cleared at every close and every gap reset,
    /// and holding scalars rather than `PoseFrame`s.
    private struct PullSample {
        let seconds: Double
        let shoulderAngle: Double
        let forwardLean: Double?
        let kneeAngle: Double?
        /// Ankle-anchored hand position in scale units — the series the force proxy differentiates.
        let handPoint: (x: Double, y: Double)?
        /// The same wrist centre in normalized image coordinates, kept for the overlay to draw.
        let handImagePoint: (x: Double, y: Double)?
        /// Whether the wrists were tracked at all — deliberately scale-free, so a pull taken before
        /// the session scale settles is not reported as a framing problem.
        let wristsVisible: Bool
        let torsoLength: Double?
    }

    private struct OpenPull {
        let catchSeconds: Double
        let catchShoulderAngle: Double
        var finishSeconds: Double?
        var finishShoulderAngle: Double?
    }
}

private extension SkiPull {
    /// Faults depend on the assembled measurements, so the record is built once and then given its
    /// faults, rather than threading a dozen values through a second initialiser.
    func replacingFaults(_ faults: [SkiFault]) -> SkiPull {
        SkiPull(
            index: index,
            startSeconds: startSeconds,
            finishSeconds: finishSeconds,
            endSeconds: endSeconds,
            catchShoulderAngle: catchShoulderAngle,
            finishShoulderAngle: finishShoulderAngle,
            catchForwardLean: catchForwardLean,
            finishForwardLean: finishForwardLean,
            peakHandSpeed: peakHandSpeed,
            peakAtDriveFraction: peakAtDriveFraction,
            catchConnection: catchConnection,
            midDriveDip: midDriveDip,
            powerTrail: powerTrail,
            leanRange: leanRange,
            kneeFlexionRange: kneeFlexionRange,
            hingeToKneeRatio: hingeToKneeRatio,
            torsoScaleSample: torsoScaleSample,
            viewpoint: viewpoint,
            facing: facing,
            handsTracked: handsTracked,
            faults: faults
        )
    }
}
