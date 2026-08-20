import Foundation

/// A single burpee broad jump, segmented into phases with the measurements each rule depends on.
///
/// A rep runs **bottom to bottom** — chest contact to chest contact — which is how a judge counts them
/// and the only definition that puts both halves of the hand/foot corridor inside one record. The
/// burpee's own chest contact is the bottom that *opens* the rep, and the broad jump follows it, so a
/// rep reads in the order the athlete performs it. Member names deliberately match `RowStroke`,
/// `SkiPull` and `WallBallRep` so a shared `MovementRep` protocol can be introduced later with no
/// edits here.
struct BurpeeRep: Equatable, Identifiable {
    var id: Int { index }

    let index: Int
    /// Seconds from the first analysed frame. This is the chest contact that opened the rep.
    let startSeconds: Double
    /// The standing peak — full extension, which for a burpee broad jump is the take-off.
    let topSeconds: Double
    /// The next chest contact, which closes this rep and opens the following one.
    let endSeconds: Double

    /// Chest height above the feet at the bottom, in torso lengths. Rule 2a and 7's measurement.
    let bottomChestHeight: Double

    /// How far the front toe passed the fingertips coming out of the bottom, in torso lengths.
    /// Positive is rule 5's violation. Nil when the hands or feet were not tracked, when the camera
    /// cannot support a horizontal measurement, or before the session scale settled.
    let toeBeyondFingertips: Double?
    /// How far ahead of the front toe the hands were planted to start the next burpee, in torso
    /// lengths. Rule 6 caps this at 30 cm.
    let handsAheadOfFrontToe: Double?
    /// How far the athlete travelled with the hands off the deck, in torso lengths — the broad jump.
    /// Reported, never faulted: rule 9 leaves the length up to the racer.
    let jumpDistance: Double?

    let viewpoint: CameraViewpoint
    let facing: Facing?
    /// Whether the hands were tracked throughout. Both corridor rules need them, and a burpee puts
    /// them on the floor at the edge of a tightly framed shot.
    let handsTracked: Bool

    let faults: [BurpeeFault]

    /// Whether the rep counts. Every `BurpeeFault` is a rule rather than an inefficiency, so this is
    /// simply whether anything fired — unlike wall balls, where only `shallowDepth` voids a rep.
    var isValid: Bool { faults.isEmpty }

    var durationSeconds: Double { endSeconds - startSeconds }

    /// Reps per minute, for pacing.
    var repRate: Double? {
        durationSeconds > 0 ? 60 / durationSeconds : nil
    }

    func hasFault(_ kind: BurpeeFault.Kind) -> Bool {
        faults.contains { $0.kind == kind }
    }
}

/// Segments burpee broad jumps and judges each one against §8.4 of the Hyrox rulebook.
///
/// **Segmentation runs on chest height above the feet** — `PoseFrame.chestHeightAboveFeet`, which
/// sweeps from about 0.2 prone to about 2.2 standing. Three properties make it the right signal, and
/// the third is the one that matters here:
///
/// - It needs only the shoulders and the ankles, the joints most likely to survive a shot framed for
///   an athlete who is about to travel out of it.
/// - Its range is enormous compared to its noise, so segmentation never comes close to the hysteresis
///   band that a knee or shoulder angle has to fight.
/// - **It needs no floor plane.** This is the one station where the athlete travels across the frame,
///   and perspective makes the floor's image height drift with x, so any estimated floor line slowly
///   goes wrong over a session. A shoulder measured against the athlete's own ankle in the same frame
///   has no such error.
///
/// The alternative worth naming and rejecting: **not the hip height**. The hips are the joint
/// MediaPipe places at the greater trochanter, and prone that landmark sits under the athlete's own
/// thigh at exactly the frame where chest contact is judged.
///
/// **Reps run bottom to bottom, so N confirmed bottoms yield N−1 reps.** The leading and trailing
/// partials are discarded — the section's first burpee is performed from standing behind the line and
/// has no preceding jump, so it is genuinely a partial. Expect `repsSoFar` to lead
/// `completedReps.count` by one, as both ergs' tallies do.
struct BurpeeRepAnalyzer {
    var thresholds: BurpeeThresholds = .default

    private(set) var completedReps: [BurpeeRep] = []
    /// Chest contacts confirmed so far. Leads `completedReps.count` by one, because a rep is not
    /// complete until the *next* contact.
    private(set) var repsSoFar = 0

    /// Reps that have closed and passed every rule.
    ///
    /// Unlike wall balls this cannot be known mid-rep. A squat is a no-rep the instant the hips fail
    /// to break parallel, but a burpee broad jump can still fail rule 6 at the very end of the rep, so
    /// validity is only settled once the rep closes. The live badge therefore lags by one rep, which
    /// is honest — the alternative is crediting a rep that is about to fail.
    var validRepsSoFar: Int { completedReps.filter(\.isValid).count }

    init(thresholds: BurpeeThresholds = .default) {
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

        guard let rawChestHeight = frame.chestHeightAboveFeet else { return }

        // A gap long enough to hide the corridor moments must not be papered over: rules 5 and 6 are
        // read at a single instant each, so a silent gap can turn a no-rep into a clean rep.
        if let last = lastSampleSeconds, seconds - last > thresholds.trackingGapSeconds {
            resetTracking()
        }
        lastSampleSeconds = seconds

        // A rep this long is a rest, not a rep.
        if let open = openRep, seconds - open.bottomSeconds > thresholds.maxRepSeconds {
            resetTracking()
        }

        chestWindow.append(rawChestHeight)
        if chestWindow.count > max(thresholds.chestSmoothingWindow, 1) {
            chestWindow.removeFirst()
        }
        guard let smoothed = smoothedChestHeight else { return }

        recordSample(from: frame, chestHeight: smoothed, at: seconds)
        advanceStateMachine(chestHeight: smoothed, at: seconds)
    }

    /// Closes out the analyzer. The rep still in progress is deliberately **not** emitted — its broad
    /// jump has not happened yet, so neither corridor measurement exists.
    mutating func finish() {
        openRep = nil
        samples.removeAll(keepingCapacity: false)
    }

    /// One-shot analysis over a complete recording.
    static func analyze(
        frames: [PoseFrame],
        thresholds: BurpeeThresholds = .default
    ) -> [BurpeeRep] {
        var analyzer = BurpeeRepAnalyzer(thresholds: thresholds)
        for frame in frames { analyzer.process(frame) }
        analyzer.finish()
        return analyzer.completedReps
    }

    // MARK: - Session-level observation

    /// Facing, scale and viewpoint are session properties rather than per-frame ones, and all three are
    /// sticky. A facing that flipped mid-rep would mirror the corridor measurements and turn a legal
    /// hand placement into a no-rep.
    private mutating func observeSession(_ frame: PoseFrame) {
        if latchedFacing == nil {
            facingTally += frame.standingFacingVote
            if abs(facingTally) >= thresholds.facingConfidenceVotes {
                latchedFacing = facingTally > 0 ? .right : .left
            }
        }

        if let torso = frame.sagittalTorsoLength { scale.observe(torso) }

        let viewpoint = frame.viewpoint(thresholds: thresholds.viewpoint)
        if viewpoint != .unknown { viewpointTally[viewpoint, default: 0] += 1 }
    }

    /// The modal viewpoint over the session, not the most recent one: the athlete is prone for part of
    /// every rep, where the shoulders foreshorten differently than they do standing, so "last" samples
    /// a random phase of that oscillation.
    private var modalViewpoint: CameraViewpoint {
        viewpointTally.max { $0.value < $1.value }?.key ?? .unknown
    }

    private var smoothedChestHeight: Double? {
        guard !chestWindow.isEmpty else { return nil }
        return chestWindow.reduce(0, +) / Double(chestWindow.count)
    }

    private mutating func recordSample(
        from frame: PoseFrame,
        chestHeight: Double,
        at seconds: Double
    ) {
        let facing = latchedFacing
        let scaleValue = scale.value

        samples.append(
            BurpeeSample(
                seconds: seconds,
                chestHeight: chestHeight,
                handHeight: frame.handHeightAboveFeet,
                toeBeyondFingertips: facing.flatMap { facing in
                    scaleValue.flatMap { frame.toeBeyondFingertips(facing: facing, scale: $0) }
                },
                handsAheadOfFrontToe: facing.flatMap { facing in
                    scaleValue.flatMap { frame.handsAheadOfFrontToe(facing: facing, scale: $0) }
                },
                travelPosition: facing.flatMap { facing in
                    scaleValue.flatMap { frame.travelPosition(facing: facing, scale: $0) }
                },
                handsVisible: frame.hasTrackedHands
            )
        )

        // Bounded: anything older than the longest rep we would ever emit cannot belong to the rep in
        // progress.
        let cutoff = seconds - (thresholds.maxRepSeconds + 1)
        while let first = samples.first, first.seconds < cutoff {
            samples.removeFirst()
        }
    }

    private mutating func resetTracking() {
        openRep = nil
        samples.removeAll(keepingCapacity: true)
        chestWindow.removeAll(keepingCapacity: true)
        phase = .unknown
        risingExtreme = nil
        fallingExtreme = nil
        confirmations = 0
        seedConfirmations = 0
    }

    // MARK: - Segmentation

    /// Locates the bottom and the top as reversals in the chest-height signal, crediting each event to
    /// where the extremum actually occurred rather than to where it was confirmed — the same idiom as
    /// `SkiPullAnalyzer.advanceStateMachine` and `WallBallRepAnalyzer.detectRelease`.
    private mutating func advanceStateMachine(chestHeight: Double, at seconds: Double) {
        switch phase {
        case .unknown:
            seedPhase(chestHeight: chestHeight, at: seconds)

        case .descending:
            // Going to the floor: looking for the bottom, the minimum.
            guard var extreme = fallingExtreme else {
                fallingExtreme = Extreme(value: chestHeight, seconds: seconds)
                return
            }
            if chestHeight < extreme.value {
                extreme = Extreme(value: chestHeight, seconds: seconds)
                fallingExtreme = extreme
                confirmations = 0
            } else if chestHeight > extreme.value + thresholds.chestReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordBottom(at: extreme.seconds, chestHeight: extreme.value)
                    phase = .rising
                    risingExtreme = Extreme(value: chestHeight, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }

        case .rising:
            // Standing and jumping: looking for the top, the maximum.
            guard var extreme = risingExtreme else {
                risingExtreme = Extreme(value: chestHeight, seconds: seconds)
                return
            }
            if chestHeight > extreme.value {
                extreme = Extreme(value: chestHeight, seconds: seconds)
                risingExtreme = extreme
                confirmations = 0
            } else if chestHeight < extreme.value - thresholds.chestReversalHysteresis {
                confirmations += 1
                if confirmations >= thresholds.confirmationFrames {
                    recordTop(at: extreme.seconds, chestHeight: extreme.value)
                    phase = .descending
                    fallingExtreme = Extreme(value: chestHeight, seconds: seconds)
                    confirmations = 0
                }
            } else {
                confirmations = 0
            }
        }
    }

    /// Until a reversal has been seen there is no way to know whether the athlete is on the way down or
    /// on the way up, so both extremes are tracked and whichever reverses first decides.
    private mutating func seedPhase(chestHeight: Double, at seconds: Double) {
        if risingExtreme == nil || chestHeight > risingExtreme!.value {
            risingExtreme = Extreme(value: chestHeight, seconds: seconds)
        }
        if fallingExtreme == nil || chestHeight < fallingExtreme!.value {
            fallingExtreme = Extreme(value: chestHeight, seconds: seconds)
        }

        guard let rising = risingExtreme, let falling = fallingExtreme else { return }

        if chestHeight > falling.value + thresholds.chestReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                recordBottom(at: falling.seconds, chestHeight: falling.value)
                phase = .rising
                risingExtreme = Extreme(value: chestHeight, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else if chestHeight < rising.value - thresholds.chestReversalHysteresis {
            seedConfirmations += 1
            if seedConfirmations >= thresholds.confirmationFrames {
                // No rep is open yet, so this top only tells us which phase we are in.
                phase = .descending
                fallingExtreme = Extreme(value: chestHeight, seconds: seconds)
                seedConfirmations = 0
                confirmations = 0
            }
        } else {
            seedConfirmations = 0
        }
    }

    private mutating func recordBottom(at seconds: Double, chestHeight: Double) {
        // This contact closes the rep the previous one opened.
        closeRep(endSeconds: seconds)

        repsSoFar += 1
        openRep = OpenRep(bottomSeconds: seconds, bottomChestHeight: chestHeight)
    }

    private mutating func recordTop(at seconds: Double, chestHeight: Double) {
        guard var open = openRep else { return }
        open.topSeconds = seconds
        open.topChestHeight = chestHeight
        openRep = open
    }

    // MARK: - Rep close

    private mutating func closeRep(endSeconds: Double) {
        guard let open = openRep else { return }
        openRep = nil

        guard let topSeconds = open.topSeconds,
              let topChestHeight = open.topChestHeight else { return }

        let duration = endSeconds - open.bottomSeconds
        guard duration >= thresholds.minRepSeconds,
              duration <= thresholds.maxRepSeconds,
              topChestHeight - open.bottomChestHeight >= thresholds.minChestRange
        else { return }

        let repSamples = samples.filter {
            $0.seconds >= open.bottomSeconds && $0.seconds <= endSeconds
        }
        guard !repSamples.isEmpty else { return }

        let rep = makeRep(
            index: completedReps.count,
            open: open,
            topSeconds: topSeconds,
            endSeconds: endSeconds,
            repSamples: repSamples
        )
        completedReps.append(rep)
    }

    private func makeRep(
        index: Int,
        open: OpenRep,
        topSeconds: Double,
        endSeconds: Double,
        repSamples: [BurpeeSample]
    ) -> BurpeeRep {
        // Deliberately three-valued. An unknown hand height is *unknown*, not "up": treating it as up
        // would hand the jump measurement a window covering the whole rep, including the long
        // backward travel into the burpee position, and report a distance the athlete never covered
        // forward. Every window below therefore tests explicitly for the state it wants, and a rep
        // with no hands simply has all three come back empty.
        func handsDown(_ sample: BurpeeSample) -> Bool? {
            sample.handHeight.map { $0 <= thresholds.handsDownHeight }
        }

        // Rule 5 is read on the way *out* of the burpee — the hands are still planted and the feet are
        // coming up to meet them. The worst frame in that window is the one a judge would call, so
        // this takes the maximum rather than an average.
        let exitOvershoot = repSamples
            .filter { $0.seconds <= topSeconds && handsDown($0) == true }
            .compactMap(\.toeBeyondFingertips)
            .max()

        // Rule 6 is read on the way *in* — at the instant the hands are planted for the next burpee,
        // which is the first hands-down frame after the take-off. Deliberately not the maximum over
        // the window: rule 7 permits stepping backwards into the burpee position once the hands are
        // down, and that step legally increases this gap. Taking the worst frame would fault the
        // athlete for the very thing the next rule along allows.
        let placementGap = repSamples
            .first { $0.seconds >= topSeconds && handsDown($0) == true }?
            .handsAheadOfFrontToe

        // The broad jump is what the athlete covers between letting go of the floor and putting the
        // hands back down. Bounded that way rather than by chest height because athletes tuck their
        // knees mid-flight, which collapses shoulder-to-ankle height and would cut the jump short.
        let travel = netTravel(
            repSamples.filter { handsDown($0) == false }.compactMap(\.travelPosition)
        )

        let rep = BurpeeRep(
            index: index,
            startSeconds: open.bottomSeconds,
            topSeconds: topSeconds,
            endSeconds: endSeconds,
            bottomChestHeight: open.bottomChestHeight,
            toeBeyondFingertips: exitOvershoot,
            handsAheadOfFrontToe: placementGap,
            jumpDistance: travel,
            viewpoint: modalViewpoint,
            facing: latchedFacing,
            handsTracked: repSamples.allSatisfy(\.handsVisible),
            faults: []
        )

        return rep.replacingFaults(faults(for: rep))
    }

    // MARK: - Travel

    /// How far the athlete moved along their direction of travel over a window, in scale units.
    ///
    /// A plain endpoint difference. An earlier version split the trace into discrete translations so
    /// it could tell the broad jump from any extra steps taken beside it, which rule 3 forbids — that
    /// check is gone (see `BurpeeFault` for why), and with it the only reason to look at the shape of
    /// the trace rather than its ends.
    ///
    /// Clamped at zero because forward is positive once `Facing` has been applied, so a negative
    /// reading is a measurement failure rather than a backward jump, and reporting one as a distance
    /// would be worse than reporting nothing happened.
    private func netTravel(_ positions: [Double]) -> Double? {
        guard let first = positions.first, let last = positions.last,
              positions.count > 1 else { return nil }

        return max(0, last - first)
    }

    // MARK: - Faults

    /// Appended in coaching priority order, because `faults.first` is what the athlete is told. See
    /// `BurpeeFault.Kind` for why the corridor leads.
    private func faults(for rep: BurpeeRep) -> [BurpeeFault] {
        var faults: [BurpeeFault] = []

        // A front-on camera cannot measure along the direction of travel — the corridor runs into the
        // depth axis rather than across the image — so every horizontal rule is suppressed. Chest
        // contact deliberately survives: it is a vertical measurement, so a front-on session still
        // judges the one rule it honestly can and goes quiet on the rest.
        let sagittalMeasurable = rep.viewpoint.supportsReachMeasurement

        if sagittalMeasurable, let gap = rep.handsAheadOfFrontToe,
           gap > thresholds.maxHandsAheadOfFrontToe {
            faults.append(.handsTooFarForward(gap: gap))
        }

        if sagittalMeasurable, let overreach = rep.toeBeyondFingertips,
           overreach > thresholds.feetPastFingertipsMargin {
            faults.append(.feetPastFingertips(overreach: overreach))
        }

        if rep.bottomChestHeight > thresholds.maxChestContactHeight {
            faults.append(.chestNotDown(clearance: rep.bottomChestHeight))
        }

        return faults
    }

    // MARK: - In-progress state

    private var anchorMilliseconds: Int?
    private var lastSampleSeconds: Double?

    private var scale: ScaleReference
    private var facingTally = 0
    private var latchedFacing: Facing?
    private var viewpointTally: [CameraViewpoint: Int] = [:]

    private var chestWindow: [Double] = []
    private var samples: [BurpeeSample] = []

    private var phase: Phase = .unknown
    private var risingExtreme: Extreme?
    private var fallingExtreme: Extreme?
    private var confirmations = 0
    private var seedConfirmations = 0
    private var openRep: OpenRep?

    private enum Phase {
        case unknown
        case descending
        case rising
    }

    private struct Extreme {
        let value: Double
        let seconds: Double
    }

    /// The in-flight rep's derived scalars.
    ///
    /// Buffered rather than streamed for the reason `SkiPullAnalyzer.PullSample` sets out: the rule
    /// measurements are each read at one instant, and which instant that is depends on the take-off,
    /// which is not known until it has happened. Bounded by `maxRepSeconds`, cleared at every close
    /// and every gap reset, and holding scalars rather than `PoseFrame`s.
    private struct BurpeeSample {
        let seconds: Double
        let chestHeight: Double
        let handHeight: Double?
        let toeBeyondFingertips: Double?
        let handsAheadOfFrontToe: Double?
        let travelPosition: Double?
        /// Deliberately scale-free, so a rep taken before the session scale settles is not reported as
        /// a framing problem.
        let handsVisible: Bool
    }

    private struct OpenRep {
        let bottomSeconds: Double
        let bottomChestHeight: Double
        var topSeconds: Double?
        var topChestHeight: Double?
    }
}

private extension BurpeeRep {
    /// Faults depend on the assembled measurements, so the record is built once and then given its
    /// faults, rather than threading a dozen values through a second initialiser.
    func replacingFaults(_ faults: [BurpeeFault]) -> BurpeeRep {
        BurpeeRep(
            index: index,
            startSeconds: startSeconds,
            topSeconds: topSeconds,
            endSeconds: endSeconds,
            bottomChestHeight: bottomChestHeight,
            toeBeyondFingertips: toeBeyondFingertips,
            handsAheadOfFrontToe: handsAheadOfFrontToe,
            jumpDistance: jumpDistance,
            viewpoint: viewpoint,
            facing: facing,
            handsTracked: handsTracked,
            faults: faults
        )
    }
}
