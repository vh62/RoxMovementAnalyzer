import Foundation

/// A single rowing stroke, segmented into phases with the measurements each fault depends on.
///
/// A stroke runs **catch to catch**, which is how a coach counts them and the only definition that
/// gives the drive-to-recovery ratio a denominator. Member names deliberately match `WallBallRep`
/// so a shared `MovementRep` protocol can be introduced later with no edits here.
struct RowStroke: Equatable, Identifiable {
    var id: Int { index }

    let index: Int
    /// Seconds from the first analysed frame. This is the catch that opened the stroke.
    let startSeconds: Double
    let finishSeconds: Double
    /// The next catch, which closes this stroke and opens the following one.
    let endSeconds: Double

    let catchKneeAngle: Double
    let finishKneeAngle: Double

    /// Torso angle at the catch, positive leaning toward the flywheel.
    let catchForwardLean: Double?
    /// Torso angle at the finish. Negative is layback.
    let finishForwardLean: Double?
    /// How far ahead of the hips the handle finished, in scale units.
    let finishHandleAheadOfHips: Double?

    /// When the legs had done their work, as a fraction of this stroke's own knee-angle range.
    let legDriveDoneSeconds: Double?
    /// When the torso began swinging back.
    let backOpenSeconds: Double?
    /// When the elbows began to bend.
    let armBreakSeconds: Double?

    /// Handle travel ÷ seat travel over the early drive. 1.0 is a stroke that kept them together.
    let slideRatio: Double?
    /// Total seat travel through the drive, in scale units.
    let seatTravel: Double?

    /// Competing scale references sampled on this stroke, carried so the better one can be chosen
    /// from real footage rather than argued about. See `PoseFrame.shinLength(_:)`.
    let torsoScaleSample: Double?
    let shinScaleSample: Double?

    let viewpoint: CameraViewpoint
    let facing: Facing?
    /// False when the wrists were not tracked throughout the drive, so handle-based faults could
    /// not be measured. On an erg the hands sit over the shins at the catch, so this is a real case.
    let handsTracked: Bool

    let faults: [RowingFault]

    var driveSeconds: Double { finishSeconds - startSeconds }
    var recoverySeconds: Double { endSeconds - finishSeconds }
    var durationSeconds: Double { endSeconds - startSeconds }

    /// Recovery ÷ drive. The coached target is about 2.0.
    var recoveryRatio: Double? {
        driveSeconds > 0 ? recoverySeconds / driveSeconds : nil
    }

    /// Strokes per minute. A metric, never a fault: the right rate depends on the athlete and where
    /// they are in the race, whereas a rushed recovery is a fault at any rate.
    var strokeRateSPM: Double? {
        durationSeconds > 0 ? 60 / durationSeconds : nil
    }

    /// Torso swing relative to the end of the leg drive. Negative means the back opened while the
    /// legs were still working. The direct analogue of `WallBallRep.releaseOffset`.
    var backSwingOffset: Double? {
        guard let backOpenSeconds, let legDriveDoneSeconds else { return nil }
        return backOpenSeconds - legDriveDoneSeconds
    }

    /// Elbow break relative to the end of the leg drive. Negative means the arms went first.
    var armBreakOffset: Double? {
        guard let armBreakSeconds, let legDriveDoneSeconds else { return nil }
        return armBreakSeconds - legDriveDoneSeconds
    }

    func hasFault(_ kind: RowingFault.Kind) -> Bool {
        faults.contains { $0.kind == kind }
    }
}

/// Segments rowing strokes and measures the technique faults in each.
///
/// Stateful and incremental (`process(_:)` per frame) so live analysis and post-session analysis run
/// identical logic, exactly as `WallBallRepAnalyzer` does.
///
/// **Segmentation runs on the near-side knee angle.** The catch is maximum knee flexion and the
/// finish is maximum knee extension — that is not a proxy for the stroke, it is the definition of
/// it, and every alternative signal is a correlate. It also sweeps ~45°→~170°, and it is scale-free
/// and translation-free, so it needs no torso-length reference and survives a handheld phone
/// drifting. That last point drives the whole design: the session scale is the shakiest assumption
/// here for a seated athlete, so segmentation stays off it and only fault *magnitudes* depend on it.
///
/// The reason wall balls could not use the knee angle — front-on, the knee travels in depth rather
/// than across the image, so it reads fully extended throughout — does not apply to a side-on erg,
/// where the sagittal plane is parallel to the image plane.
///
/// The near side is used rather than the maximum of both. `legExtensionAngle` takes the maximum
/// because wall balls asks whether *anyone's* leg is straight; here we need the minimum at the catch,
/// and the maximum is biased by the occluded far leg, which MediaPipe tends to estimate straighter
/// than it is. That would systematically hide a short catch.
///
/// **Strokes run catch to catch, so N confirmed catches yield N−1 strokes.** The leading and
/// trailing partials are discarded because their drive or recovery time is unknown, and half the
/// fault set is unmeasurable without it. This differs from `WallBallRepAnalyzer`, which emits its
/// trailing open rep — expect `strokesSoFar` to lead `completedStrokes.count` by one.
///
/// If the ankle turns out to track badly behind the foot straps and footplate housing, the fallback
/// signal is `kneeY − hipY`: the seat rides at a constant rail height, so hip y is near-constant
/// while knee y sweeps, and it needs no ankle at all. It would replace `smoothedKneeAngle` and
/// nothing else.
struct RowStrokeAnalyzer {
    var thresholds: RowingThresholds = .default

    private(set) var completedStrokes: [RowStroke] = []
    /// Catches confirmed so far — the live-display counterpart of `validRepsSoFar`. Leads
    /// `completedStrokes.count` by one, because a stroke is not complete until the *next* catch.
    private(set) var strokesSoFar = 0

    init(thresholds: RowingThresholds = .default) {
        self.thresholds = thresholds
        self.scale = ScaleReference(
            minimumSamples: thresholds.minScaleSamples,
            outlierTolerance: thresholds.scaleOutlierTolerance
        )
    }

    // MARK: - Frame intake

    mutating func process(_ frame: PoseFrame) {
        if anchorMilliseconds == nil { anchorMilliseconds = frame.timestampInMilliseconds }
        let seconds = Double(frame.timestampInMilliseconds - (anchorMilliseconds ?? 0)) / 1000

        observeSession(frame)

        guard let side = nearSide,
              let rawKneeAngle = frame.kneeAngle(side) else { return }

        // A gap long enough to distort a phase must not be papered over: three of the four fault
        // families are timing- or displacement-based, so a silent gap manufactures faults.
        if let last = lastSampleSeconds, seconds - last > thresholds.trackingGapSeconds {
            resetTracking()
        }
        lastSampleSeconds = seconds

        // A stroke this long is a rest between pieces, not a stroke. Drop it rather than reporting
        // one 40-second stroke at 1.5 spm.
        if let open = openStroke, seconds - open.catchSeconds > thresholds.maxStrokeSeconds {
            resetTracking()
        }

        kneeWindow.append(rawKneeAngle)
        if kneeWindow.count > max(thresholds.kneeSmoothingWindow, 1) {
            kneeWindow.removeFirst()
        }
        guard let smoothed = smoothedKneeAngle else { return }

        recordSample(from: frame, side: side, kneeAngle: smoothed, at: seconds)
        advanceStateMachine(kneeAngle: smoothed, at: seconds)
    }

    /// Closes out the analyzer. The stroke still in progress is deliberately **not** emitted — its
    /// recovery has not happened yet, so its ratio and finish measurements do not exist.
    mutating func finish() {
        openStroke = nil
        samples.removeAll(keepingCapacity: false)
    }

    /// One-shot analysis over a complete recording.
    static func analyze(
        frames: [PoseFrame],
        thresholds: RowingThresholds = .default
    ) -> [RowStroke] {
        var analyzer = RowStrokeAnalyzer(thresholds: thresholds)
        for frame in frames { analyzer.process(frame) }
        analyzer.finish()
        return analyzer.completedStrokes
    }

    // MARK: - Session-level observation

    /// Facing, near side, scale and viewpoint are all session properties rather than per-frame ones,
    /// and all four are deliberately sticky. A value that flips mid-stroke would mirror or rescale
    /// one sample's measurements and read as a violent handle reversal.
    private mutating func observeSession(_ frame: PoseFrame) {
        if latchedFacing == nil {
            facingTally += frame.facingVote
            if abs(facingTally) >= thresholds.facingConfidenceVotes {
                latchedFacing = facingTally > 0 ? .right : .left
            }
        }

        if latchedSide == nil {
            leftConfidence += frame.sagittalConfidence(.left)
            rightConfidence += frame.sagittalConfidence(.right)
            sideVotes += 1
            if sideVotes >= thresholds.sideVoteFrames {
                latchedSide = rightConfidence > leftConfidence ? .right : .left
            }
        }

        if let torso = frame.sagittalTorsoLength { scale.observe(torso) }

        let viewpoint = frame.viewpoint(thresholds: thresholds.viewpoint)
        if viewpoint != .unknown { viewpointTally[viewpoint, default: 0] += 1 }
    }

    /// The side to measure. Before the vote settles this follows whichever side is currently ahead,
    /// so analysis is not stalled for the first half-second.
    private var nearSide: BodySide? {
        if let latchedSide { return latchedSide }
        guard sideVotes > 0 else { return nil }
        return rightConfidence > leftConfidence ? .right : .left
    }

    /// The modal viewpoint over the session, not the most recent one.
    ///
    /// `WallBallRepAnalyzer` latches the last non-unknown value, which is fine for a standing
    /// athlete. A seated rower's shoulder-to-torso ratio oscillates with the stroke, so "last"
    /// samples a random phase of it.
    private var modalViewpoint: CameraViewpoint {
        viewpointTally.max { $0.value < $1.value }?.key ?? .unknown
    }

    private var smoothedKneeAngle: Double? {
        guard !kneeWindow.isEmpty else { return nil }
        return kneeWindow.reduce(0, +) / Double(kneeWindow.count)
    }

    private mutating func recordSample(
        from frame: PoseFrame,
        side: BodySide,
        kneeAngle: Double,
        at seconds: Double
    ) {
        let facing = latchedFacing
        let scaleValue = scale.value

        samples.append(
            StrokeSample(
                seconds: seconds,
                kneeAngle: kneeAngle,
                forwardLean: facing.flatMap { frame.forwardTorsoLean(facing: $0) },
                elbowAngle: frame.elbowAngle(side),
                seatOffset: offset(frame, facing, scaleValue) { $0.seatOffset(facing: $1, scale: $2) },
                handleOffset: offset(frame, facing, scaleValue) { $0.handleOffset(facing: $1, scale: $2) },
                handleAheadOfHips: offset(frame, facing, scaleValue) {
                    $0.handleAheadOfHips(facing: $1, scale: $2)
                },
                torsoLength: frame.sagittalTorsoLength,
                shinLength: frame.shinLength(side)
            )
        )

        // Bounded: anything older than the longest stroke we would ever emit cannot belong to the
        // stroke in progress.
        let cutoff = seconds - (thresholds.maxStrokeSeconds + 1)
        while let first = samples.first, first.seconds < cutoff {
            samples.removeFirst()
        }
    }

    private func offset(
        _ frame: PoseFrame,
        _ facing: Facing?,
        _ scale: Double?,
        _ measure: (PoseFrame, Facing, Double) -> Double?
    ) -> Double? {
        guard let facing, let scale else { return nil }
        return measure(frame, facing, scale)
    }

    private mutating func resetTracking() {
        openStroke = nil
        samples.removeAll(keepingCapacity: true)
        kneeWindow.removeAll(keepingCapacity: true)
        phase = .unknown
        risingExtreme = nil
        fallingExtreme = nil
        confirmations = 0
    }

    // MARK: - Segmentation

    /// Locates the catch and the finish as reversals in the knee angle, crediting each event to
    /// where the extremum actually occurred rather than to where it was confirmed — the same idiom
    /// as `WallBallRepAnalyzer.detectRelease`.
    ///
    /// Amplitude hysteresis with consecutive-frame confirmation, rather than a velocity threshold:
    /// angular rate varies hugely with stroke rate, but 8° is 8° at any rate, and a pause at the
    /// catch is then handled for free — the running minimum simply sits there until the athlete
    /// actually drives.
    private mutating func advanceStateMachine(kneeAngle: Double, at seconds: Double) {
        switch phase {
        case .unknown:
            seedPhase(kneeAngle: kneeAngle, at: seconds)

        case .drive:
            // Knees extending: looking for the finish, the maximum.
            guard var extreme = risingExtreme else {
                risingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                return
            }
            if kneeAngle > extreme.value {
                extreme = Extreme(value: kneeAngle, seconds: seconds)
                risingExtreme = extreme
                confirmations = 0
            } else if kneeAngle < extreme.value - thresholds.kneeReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordFinish(at: extreme.seconds, kneeAngle: extreme.value)
                    phase = .recovery
                    fallingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }

        case .recovery:
            // Knees flexing: looking for the catch, the minimum.
            guard var extreme = fallingExtreme else {
                fallingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                return
            }
            if kneeAngle < extreme.value {
                extreme = Extreme(value: kneeAngle, seconds: seconds)
                fallingExtreme = extreme
                confirmations = 0
            } else if kneeAngle > extreme.value + thresholds.kneeReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordCatch(at: extreme.seconds, kneeAngle: extreme.value)
                    phase = .drive
                    risingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }
        }
    }

    /// Until a reversal has been seen there is no way to know whether the athlete is driving or
    /// recovering, so both extremes are tracked and whichever reverses first decides.
    private mutating func seedPhase(kneeAngle: Double, at seconds: Double) {
        if risingExtreme == nil || kneeAngle > risingExtreme!.value {
            risingExtreme = Extreme(value: kneeAngle, seconds: seconds)
        }
        if fallingExtreme == nil || kneeAngle < fallingExtreme!.value {
            fallingExtreme = Extreme(value: kneeAngle, seconds: seconds)
        }

        guard let rising = risingExtreme, let falling = fallingExtreme else { return }

        if kneeAngle > falling.value + thresholds.kneeReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                recordCatch(at: falling.seconds, kneeAngle: falling.value)
                phase = .drive
                risingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else if kneeAngle < rising.value - thresholds.kneeReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                // No stroke is open yet, so this finish only tells us which phase we are in.
                phase = .recovery
                fallingExtreme = Extreme(value: kneeAngle, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else {
            seedConfirmations = 0
        }
    }

    private mutating func recordCatch(at seconds: Double, kneeAngle: Double) {
        // This catch closes the stroke the previous one opened.
        closeStroke(endSeconds: seconds)

        strokesSoFar += 1
        openStroke = OpenStroke(catchSeconds: seconds, catchKneeAngle: kneeAngle)
    }

    private mutating func recordFinish(at seconds: Double, kneeAngle: Double) {
        guard var open = openStroke else { return }
        open.finishSeconds = seconds
        open.finishKneeAngle = kneeAngle
        openStroke = open
    }

    // MARK: - Stroke close

    private mutating func closeStroke(endSeconds: Double) {
        guard let open = openStroke else { return }
        openStroke = nil

        guard let finishSeconds = open.finishSeconds,
              let finishKneeAngle = open.finishKneeAngle else { return }

        let duration = endSeconds - open.catchSeconds
        guard duration >= thresholds.minStrokeSeconds,
              duration <= thresholds.maxStrokeSeconds,
              finishKneeAngle - open.catchKneeAngle >= thresholds.minStrokeKneeRange else { return }

        let strokeSamples = samples.filter {
            $0.seconds >= open.catchSeconds && $0.seconds <= endSeconds
        }
        let driveSamples = strokeSamples.filter { $0.seconds <= finishSeconds }
        guard !driveSamples.isEmpty else { return }

        let stroke = makeStroke(
            index: completedStrokes.count,
            open: open,
            finishSeconds: finishSeconds,
            finishKneeAngle: finishKneeAngle,
            endSeconds: endSeconds,
            strokeSamples: strokeSamples,
            driveSamples: driveSamples
        )
        completedStrokes.append(stroke)
    }

    private func makeStroke(
        index: Int,
        open: OpenStroke,
        finishSeconds: Double,
        finishKneeAngle: Double,
        endSeconds: Double,
        strokeSamples: [StrokeSample],
        driveSamples: [StrokeSample]
    ) -> RowStroke {
        let catchSample = driveSamples[0]
        let finishSample = driveSamples[driveSamples.count - 1]

        // Every intra-stroke event is measured against *this* stroke's own range. Rowing has no
        // absolute reference the way wall balls has `standingDelta`: a 175° finish for one athlete
        // is 162° for another, and the catch angle depends on leg length and foot-stretcher setting.
        let kneeRange = finishKneeAngle - open.catchKneeAngle
        let legDriveDoneSeconds = driveSamples.first {
            ($0.kneeAngle - open.catchKneeAngle) / kneeRange >= thresholds.legDriveProgress
        }?.seconds

        let catchLean = driveSamples.first { $0.forwardLean != nil }?.forwardLean
        let backOpenSeconds = catchLean.flatMap { lean in
            firstSustained(in: driveSamples) {
                guard let value = $0.forwardLean else { return false }
                return value <= lean - thresholds.backOpenLeanDelta
            }
        }

        let catchElbow = driveSamples.first { $0.elbowAngle != nil }?.elbowAngle
        let armBreakSeconds = catchElbow.flatMap { elbow in
            firstSustained(in: driveSamples) {
                guard let value = $0.elbowAngle else { return false }
                return value <= elbow - thresholds.armBreakAngleDelta
            }
        }

        let slide = slideMeasurement(driveSamples: driveSamples)
        let handsTracked = driveSamples.allSatisfy { $0.handleOffset != nil }

        let stroke = RowStroke(
            index: index,
            startSeconds: open.catchSeconds,
            finishSeconds: finishSeconds,
            endSeconds: endSeconds,
            catchKneeAngle: open.catchKneeAngle,
            finishKneeAngle: finishKneeAngle,
            catchForwardLean: catchLean,
            finishForwardLean: finishSample.forwardLean,
            finishHandleAheadOfHips: finishSample.handleAheadOfHips,
            legDriveDoneSeconds: legDriveDoneSeconds,
            backOpenSeconds: backOpenSeconds,
            armBreakSeconds: armBreakSeconds,
            slideRatio: slide.ratio,
            seatTravel: slide.seatTravel,
            torsoScaleSample: catchSample.torsoLength,
            shinScaleSample: catchSample.shinLength,
            viewpoint: modalViewpoint,
            facing: latchedFacing,
            handsTracked: handsTracked,
            faults: []
        )

        return stroke.replacingFaults(faults(for: stroke, handsTracked: handsTracked))
    }

    /// Handle travel ÷ seat travel over the early drive.
    ///
    /// With straight arms and a fixed body angle the handle travels exactly as far as the seat, so a
    /// clean stroke sits at 1.0 and anything well below it means the hips ran out from under the
    /// athlete. The window is bounded by **seat travel rather than time**, so a 24 spm and a 32 spm
    /// stroke are compared over the same portion of the slide.
    private func slideMeasurement(driveSamples: [StrokeSample]) -> (ratio: Double?, seatTravel: Double?) {
        guard let catchSeat = driveSamples.first(where: { $0.seatOffset != nil })?.seatOffset,
              let catchHandle = driveSamples.first(where: { $0.handleOffset != nil })?.handleOffset,
              let finishSeat = driveSamples.last(where: { $0.seatOffset != nil })?.seatOffset
        else { return (nil, nil) }

        let seatTravel = finishSeat - catchSeat
        guard seatTravel >= thresholds.minSeatTravel else { return (nil, seatTravel) }

        let windowTarget = catchSeat + seatTravel * thresholds.slideWindowSeatFraction
        guard let windowEnd = driveSamples.first(where: { ($0.seatOffset ?? -.infinity) >= windowTarget }),
              let windowSeat = windowEnd.seatOffset,
              let windowHandle = windowEnd.handleOffset else { return (nil, seatTravel) }

        let seatDelta = windowSeat - catchSeat
        guard seatDelta > 0 else { return (nil, seatTravel) }

        return ((windowHandle - catchHandle) / seatDelta, seatTravel)
    }

    /// First moment of a run of `confirmationFrames` consecutive satisfying samples, credited to
    /// where the run began rather than where it was confirmed.
    private func firstSustained(
        in samples: [StrokeSample],
        where predicate: (StrokeSample) -> Bool
    ) -> Double? {
        var runStart: Double?
        var count = 0

        for sample in samples {
            if predicate(sample) {
                if runStart == nil { runStart = sample.seconds }
                count += 1
                if count >= thresholds.confirmationFrames { return runStart }
            } else {
                runStart = nil
                count = 0
            }
        }
        return nil
    }

    // MARK: - Faults

    /// Appended in coaching priority order, because `faults.first` is what the athlete is told.
    ///
    /// Unlike wall balls there is no rule-versus-inefficiency distinction to respect — the erg counts
    /// the metres either way — so this is purely which correction to make first: sequencing leaks
    /// the most power and causes the rest, range of motion is free metres left on the table, and
    /// rhythm is real but often resolves itself once the sequence is fixed.
    private func faults(for stroke: RowStroke, handsTracked: Bool) -> [RowingFault] {
        var faults: [RowingFault] = []
        let horizontalMeasurable = stroke.viewpoint.supportsReachMeasurement

        if let offset = stroke.armBreakOffset, offset < thresholds.earlySequenceOffset {
            faults.append(.sequenceArmsTooEarly(offset: offset))
        }

        if let offset = stroke.backSwingOffset, offset < thresholds.earlySequenceOffset {
            faults.append(.sequenceBackTooEarly(offset: offset))
        }

        // Only the low side is a fault. A ratio above 1 means the handle outran the seat, which is
        // the back or the arms going early — already reported above, and saying it twice would just
        // put the same finding in two places.
        if horizontalMeasurable, handsTracked,
           let ratio = stroke.slideRatio, ratio < thresholds.minSlideRatio {
            faults.append(.shootingTheSlide(handleTravelRatio: ratio))
        }

        if stroke.catchKneeAngle > thresholds.maxCatchKneeAngle {
            faults.append(.incompleteCatch(kneeAngle: stroke.catchKneeAngle))
        }

        if let lean = stroke.finishForwardLean, lean > -thresholds.minFinishLayback {
            faults.append(.noLayback(lean: lean))
        }

        if horizontalMeasurable, handsTracked,
           let distance = stroke.finishHandleAheadOfHips,
           distance > thresholds.maxFinishHandleDistance {
            faults.append(.shortFinish(handleDistance: distance))
        }

        if let ratio = stroke.recoveryRatio, ratio < thresholds.minRecoveryRatio {
            faults.append(.rushingTheRecovery(ratio: ratio))
        }

        return faults
    }

    // MARK: - In-progress state

    private var anchorMilliseconds: Int?
    private var lastSampleSeconds: Double?

    private var scale: ScaleReference
    private var facingTally = 0
    private var latchedFacing: Facing?
    private var leftConfidence: Double = 0
    private var rightConfidence: Double = 0
    private var sideVotes = 0
    private var latchedSide: BodySide?
    private var viewpointTally: [CameraViewpoint: Int] = [:]

    private var kneeWindow: [Double] = []
    private var samples: [StrokeSample] = []

    private var phase: Phase = .unknown
    private var risingExtreme: Extreme?
    private var fallingExtreme: Extreme?
    private var confirmations = 0
    private var seedConfirmations = 0
    private var openStroke: OpenStroke?

    private enum Phase {
        case unknown
        case drive
        case recovery
    }

    private struct Extreme {
        let value: Double
        let seconds: Double
    }

    /// The in-flight stroke's derived scalars.
    ///
    /// `WallBallRepAnalyzer` is purely forward-streaming; rowing cannot be, because almost every
    /// measurement here is relative to the stroke's own range at *both* ends, which is not known
    /// until the stroke closes. Seven doubles per frame, bounded by `maxStrokeSeconds`, cleared at
    /// every close and every gap reset — and not `PoseFrame`s.
    private struct StrokeSample {
        let seconds: Double
        let kneeAngle: Double
        let forwardLean: Double?
        let elbowAngle: Double?
        let seatOffset: Double?
        let handleOffset: Double?
        let handleAheadOfHips: Double?
        let torsoLength: Double?
        let shinLength: Double?
    }

    private struct OpenStroke {
        let catchSeconds: Double
        let catchKneeAngle: Double
        var finishSeconds: Double?
        var finishKneeAngle: Double?
    }
}

private extension RowStroke {
    /// Faults depend on the assembled measurements, so the record is built once and then given its
    /// faults, rather than threading a dozen values through a second initialiser.
    func replacingFaults(_ faults: [RowingFault]) -> RowStroke {
        RowStroke(
            index: index,
            startSeconds: startSeconds,
            finishSeconds: finishSeconds,
            endSeconds: endSeconds,
            catchKneeAngle: catchKneeAngle,
            finishKneeAngle: finishKneeAngle,
            catchForwardLean: catchForwardLean,
            finishForwardLean: finishForwardLean,
            finishHandleAheadOfHips: finishHandleAheadOfHips,
            legDriveDoneSeconds: legDriveDoneSeconds,
            backOpenSeconds: backOpenSeconds,
            armBreakSeconds: armBreakSeconds,
            slideRatio: slideRatio,
            seatTravel: seatTravel,
            torsoScaleSample: torsoScaleSample,
            shinScaleSample: shinScaleSample,
            viewpoint: viewpoint,
            facing: facing,
            handsTracked: handsTracked,
            faults: faults
        )
    }
}
