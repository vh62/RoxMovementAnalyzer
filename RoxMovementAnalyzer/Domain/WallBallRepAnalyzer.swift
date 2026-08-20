import Foundation

/// A single wall-ball rep, segmented into phases with the measurements each fault depends on.
struct WallBallRep: Equatable, Identifiable {
    var id: Int { index }

    let index: Int
    /// Seconds from the first analysed frame.
    let startSeconds: Double
    let bottomSeconds: Double
    let endSeconds: Double

    let reachedDepth: Bool
    let deepestDelta: Double

    /// When the legs reached full extension on the way up.
    let legExtendedSeconds: Double?
    /// When the arms began driving the ball upward.
    let armDriveStartSeconds: Double?
    /// Peak arm extension — the ball leaving the hands.
    let releaseSeconds: Double?
    /// When the descending hands stopped falling, i.e. received the ball.
    let catchSeconds: Double?
    /// Horizontal hand distance from the shoulders at the catch, in torso lengths.
    let catchReach: Double?

    let viewpoint: CameraViewpoint
    /// False when the wrists left frame during the throw, so release could not be measured.
    let handsTracked: Bool

    let faults: [WallBallFault]

    /// Arm drive relative to full leg extension. Negative means the arms went first (the legs
    /// had not finished), positive means there was a pause at the top.
    var releaseOffset: Double? {
        guard let armDriveStartSeconds, let legExtendedSeconds else { return nil }
        return armDriveStartSeconds - legExtendedSeconds
    }

    var durationSeconds: Double { endSeconds - startSeconds }

    func hasFault(_ kind: WallBallFault.Kind) -> Bool {
        faults.contains { $0.kind == kind }
    }
}

/// Segments wall-ball reps and measures the movement inefficiencies in each.
///
/// Stateful and incremental (`process(_:)` per frame) so live analysis and post-session analysis
/// run identical logic. `WallBallRepCounter` is a thin wrapper over this, so there is exactly one
/// rep state machine in the app.
///
/// Depth uses `delta = hipY - kneeY` in normalized image coordinates (y increases downward):
/// standing gives a clearly negative delta, hip-below-knee gives delta >= 0.
///
/// A rep stays open past the stand-up so the *catch* that follows the throw can be measured; it is
/// finalised at the catch, or when the next descent begins, whichever comes first.
struct WallBallRepAnalyzer {
    var thresholds: WallBallThresholds = .default

    private(set) var completedReps: [WallBallRep] = []
    /// Valid reps as of right now — increments the instant depth is reached, for live display.
    private(set) var validRepsSoFar = 0
    private(set) var attempts = 0
    private(set) var deepestDelta: Double?

    private var anchorMilliseconds: Int?
    private var openRep: OpenRep?
    private var armSamples: [ArmSample] = []
    private var lastViewpoint: CameraViewpoint = .unknown
    private var sideVote = NearSideVote(voteFrames: WallBallThresholds.default.sideVoteFrames)

    /// The side the overlay should draw, or nil to draw both.
    ///
    /// Gated on `lastViewpoint` rather than a modal tally, which is what this analyzer already uses:
    /// for a standing athlete the shoulder-to-torso ratio does not oscillate the way a seated rower's
    /// does, so the most recent reading is representative.
    var profileSide: BodySide? {
        guard lastViewpoint.supportsReachMeasurement else { return nil }
        return sideVote.confidentSide
    }

    // MARK: - Frame intake

    mutating func process(_ frame: PoseFrame) {
        guard let hipY = frame.visibleAverageY(.leftHip, .rightHip),
              let kneeY = frame.visibleAverageY(.leftKnee, .rightKnee) else { return }

        if anchorMilliseconds == nil { anchorMilliseconds = frame.timestampInMilliseconds }
        let seconds = Double(frame.timestampInMilliseconds - (anchorMilliseconds ?? 0)) / 1000

        let delta = hipY - kneeY
        deepestDelta = max(deepestDelta ?? delta, delta)

        let viewpoint = frame.viewpoint(thresholds: thresholds.viewpoint)
        if viewpoint != .unknown { lastViewpoint = viewpoint }

        // Wall balls takes no side for *measurement* — depth reads whichever hip and knee are visible
        // — so this exists purely to tell the overlay which half of a profile athlete is real.
        sideVote.observe(frame)

        recordArmSample(from: frame, at: seconds)

        if var rep = openRep {
            advance(&rep, frame: frame, delta: delta, seconds: seconds)
            openRep = rep

            // A new descent means the previous rep is done, catch or no catch.
            if rep.hasStoodUp, delta > thresholds.descentDelta {
                finalizeOpenRep()
                beginRep(at: seconds, delta: delta)
                return
            }

            if rep.hasStoodUp, !rep.reachedDepth {
                finalizeOpenRep()
                return
            }

            if rep.isComplete {
                finalizeOpenRep()
            }
            return
        }

        if delta > thresholds.descentDelta || delta >= thresholds.validDepthDelta {
            beginRep(at: seconds, delta: delta)
        }
    }

    /// Closes out any rep still in progress. Call once after the last frame.
    mutating func finish() {
        finalizeOpenRep()
    }

    /// One-shot analysis over a complete recording.
    static func analyze(
        frames: [PoseFrame],
        thresholds: WallBallThresholds = .default
    ) -> [WallBallRep] {
        var analyzer = WallBallRepAnalyzer()
        analyzer.thresholds = thresholds
        for frame in frames { analyzer.process(frame) }
        analyzer.finish()
        return analyzer.completedReps
    }

    // MARK: - Rep lifecycle

    private mutating func beginRep(at seconds: Double, delta: Double) {
        attempts += 1
        var rep = OpenRep(index: attempts - 1, startSeconds: seconds, deepestDelta: delta, bottomSeconds: seconds)

        if delta >= thresholds.validDepthDelta {
            rep.reachedDepth = true
            validRepsSoFar += 1
        }

        openRep = rep
    }

    private mutating func advance(
        _ rep: inout OpenRep,
        frame: PoseFrame,
        delta: Double,
        seconds: Double
    ) {
        rep.lastSeenSeconds = seconds

        if delta > rep.deepestDelta {
            rep.deepestDelta = delta
            rep.bottomSeconds = seconds
        }

        // Count the rep the instant legal depth is reached, matching the live badge.
        if delta >= thresholds.validDepthDelta, !rep.reachedDepth {
            rep.reachedDepth = true
            validRepsSoFar += 1
        }

        if frame.hasTrackedHands { rep.handsTracked = true }

        // Everything below is about the drive, so only look after the bottom of the squat.
        guard seconds > rep.bottomSeconds else { return }

        // Full leg extension = the hips have travelled back to (nearly) standing height, measured
        // against this rep's own depth so it works for a deep or a shallow squat alike.
        if rep.legExtendedSeconds == nil {
            let range = thresholds.standingDelta - rep.deepestDelta
            if abs(range) > 0.001 {
                let progress = (delta - rep.deepestDelta) / range
                if progress >= thresholds.legExtensionProgress {
                    rep.legExtendedSeconds = seconds
                }
            }
        }

        detectArmDrive(&rep, at: seconds)
        detectRelease(&rep, at: seconds)

        if delta < thresholds.descentDelta, !rep.hasStoodUp {
            rep.hasStoodUp = true
            rep.endSeconds = seconds
        }

        detectCatch(&rep, frame: frame, at: seconds)
    }

    private mutating func finalizeOpenRep() {
        guard let rep = openRep else { return }
        openRep = nil

        let record = makeRecord(from: rep)
        completedReps.append(record)
    }

    private func makeRecord(from rep: OpenRep) -> WallBallRep {
        let releaseOffset: Double? = {
            guard let armStart = rep.armDriveStartSeconds, let legExtended = rep.legExtendedSeconds
            else { return nil }
            return armStart - legExtended
        }()

        var faults: [WallBallFault] = []

        // Depth goes first deliberately. It is the rule that voids the rep rather than an
        // inefficiency, so when a rep is both shallow and mistimed this is what `faults.first`
        // surfaces to the athlete.
        if !rep.reachedDepth {
            faults.append(
                .shallowDepth(shortfall: (thresholds.validDepthDelta - rep.deepestDelta) * 100)
            )
        }

        if let releaseOffset {
            if releaseOffset < thresholds.earlyReleaseOffset {
                faults.append(.earlyRelease(offset: releaseOffset))
            } else if releaseOffset > thresholds.lateReleaseOffset {
                faults.append(.lateRelease(offset: releaseOffset))
            }
        }

        // Horizontal reach is only meaningful when we can see the athlete from the side.
        if lastViewpoint.supportsReachMeasurement,
           let reach = rep.catchReach, reach > thresholds.catchReachLimit {
            faults.append(.catchTooFarForward(reach: reach))
        }

        return WallBallRep(
            index: rep.index,
            startSeconds: rep.startSeconds,
            bottomSeconds: rep.bottomSeconds,
            endSeconds: rep.endSeconds ?? rep.lastSeenSeconds,
            reachedDepth: rep.reachedDepth,
            deepestDelta: rep.deepestDelta,
            legExtendedSeconds: rep.legExtendedSeconds,
            armDriveStartSeconds: rep.armDriveStartSeconds,
            releaseSeconds: rep.releaseSeconds,
            catchSeconds: rep.catchSeconds,
            catchReach: rep.catchReach,
            viewpoint: lastViewpoint,
            handsTracked: rep.handsTracked,
            faults: faults
        )
    }

    // MARK: - Arm signal

    private mutating func recordArmSample(from frame: PoseFrame, at seconds: Double) {
        guard let height = frame.armHeightAboveShoulders else { return }

        armSamples.append(ArmSample(seconds: seconds, height: height, reach: frame.handReachFromShoulders))
        if armSamples.count > max(thresholds.armSmoothingWindow, 1) * 3 {
            armSamples.removeFirst()
        }
    }

    /// Moving average of recent arm heights — raw per-frame values are too noisy at ~30 fps to
    /// find the onset and peak reliably.
    private var smoothedArmHeight: Double? {
        guard !armSamples.isEmpty else { return nil }
        let window = min(max(thresholds.armSmoothingWindow, 1), armSamples.count)
        let recent = armSamples.suffix(window)
        return recent.map(\.height).reduce(0, +) / Double(window)
    }

    /// Tracks the most recent sustained rise in arm height. Deliberately does not latch: the onset
    /// that matters is the one immediately preceding the throw's peak, so `detectRelease` pairs
    /// them up rather than trusting the first rise it sees.
    private mutating func detectArmDrive(_ rep: inout OpenRep, at seconds: Double) {
        guard let current = smoothedArmHeight else { return }

        defer {
            rep.previousArmHeight = current
            rep.previousArmSeconds = seconds
        }

        guard let previous = rep.previousArmHeight,
              let previousTime = rep.previousArmSeconds,
              seconds > previousTime else { return }

        let velocity = (current - previous) / (seconds - previousTime)

        if velocity >= thresholds.armDriveVelocity {
            if rep.armDriveRunStart == nil { rep.armDriveRunStart = previousTime }
            rep.armDriveFrameCount += 1

            if rep.armDriveFrameCount >= thresholds.armDriveFrames {
                // Credit the drive to where the rise began, not where it was confirmed.
                rep.currentArmOnset = rep.armDriveRunStart
            }
        } else {
            rep.armDriveFrameCount = 0
            rep.armDriveRunStart = nil
        }
    }

    private mutating func detectRelease(_ rep: inout OpenRep, at seconds: Double) {
        // Only track the peak once the arms are actually driving. Before that the shoulders are
        // dropping toward hands carried at chest height, which looks like the hands rising.
        guard rep.releaseSeconds == nil,
              rep.currentArmOnset != nil,
              let current = smoothedArmHeight else { return }

        if current > rep.peakArmHeight {
            rep.peakArmHeight = current
            rep.peakArmSeconds = seconds
            // Pair the peak with the rise that produced it.
            rep.onsetForPeak = rep.currentArmOnset
            rep.framesSincePeak = 0
            return
        }

        // A throw finishes with the hands above the shoulders; anything lower is not a release.
        guard rep.peakArmSeconds != nil,
              rep.peakArmHeight >= thresholds.minReleaseArmHeight else { return }

        // Only once the hands are clearly on the way down do we know the peak has passed.
        rep.framesSincePeak += 1
        if rep.framesSincePeak >= 2 {
            rep.releaseSeconds = rep.peakArmSeconds
            rep.armDriveStartSeconds = rep.onsetForPeak
        }
    }

    private mutating func detectCatch(_ rep: inout OpenRep, frame: PoseFrame, at seconds: Double) {
        // The catch is the moment the falling hands stop falling, after the ball has been thrown.
        guard rep.releaseSeconds != nil, rep.catchSeconds == nil,
              let current = smoothedArmHeight else { return }

        if let lowest = rep.lowestArmHeightAfterRelease {
            if current < lowest {
                rep.lowestArmHeightAfterRelease = current
                rep.lowestArmSeconds = seconds
                rep.lowestArmReach = frame.handReachFromShoulders
                rep.framesSinceLowest = 0
            } else {
                rep.framesSinceLowest += 1
                if rep.framesSinceLowest >= 2 {
                    rep.catchSeconds = rep.lowestArmSeconds
                    rep.catchReach = rep.lowestArmReach
                }
            }
        } else {
            rep.lowestArmHeightAfterRelease = current
            rep.lowestArmSeconds = seconds
            rep.lowestArmReach = frame.handReachFromShoulders
        }
    }

    // MARK: - In-progress state

    private struct ArmSample {
        let seconds: Double
        let height: Double
        let reach: Double?
    }

    private struct OpenRep {
        let index: Int
        let startSeconds: Double
        var deepestDelta: Double
        var bottomSeconds: Double
        var reachedDepth = false
        var handsTracked = false
        var hasStoodUp = false

        var legExtendedSeconds: Double?
        var armDriveStartSeconds: Double?
        var releaseSeconds: Double?
        var catchSeconds: Double?
        var catchReach: Double?
        var endSeconds: Double?
        var lastSeenSeconds: Double = 0

        // Arm-drive onset detection
        var previousArmHeight: Double?
        var previousArmSeconds: Double?
        var armDriveFrameCount = 0
        var armDriveRunStart: Double?
        /// Most recent confirmed rise, which may or may not turn out to be the throw.
        var currentArmOnset: Double?

        // Release peak detection
        var peakArmHeight: Double = -.greatestFiniteMagnitude
        var peakArmSeconds: Double?
        var onsetForPeak: Double?
        var framesSincePeak = 0

        // Catch detection
        var lowestArmHeightAfterRelease: Double?
        var lowestArmSeconds: Double?
        var lowestArmReach: Double?
        var framesSinceLowest = 0

        /// Once the athlete has stood and the catch has been measured there is nothing left to see.
        var isComplete: Bool { hasStoodUp && catchSeconds != nil }
    }
}
