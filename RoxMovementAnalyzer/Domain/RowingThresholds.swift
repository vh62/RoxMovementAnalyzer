import Foundation

/// Every tunable constant behind RowErg analysis, in one place.
///
/// **These are informed starting estimates, not calibrated values.** No RowErg footage has been
/// measured against them. Angles are in degrees, times in seconds, and distances in torso lengths
/// (the session-level scale from `ScaleReference`) so they do not change with the athlete's
/// distance from the camera.
///
/// Analysis assumes the athlete is filmed **side-on**, which is what makes the sagittal plane
/// parallel to the image plane and the knee angle honest. Horizontal measurements are suppressed
/// when the viewpoint says otherwise.
struct RowingThresholds: Equatable {
    static let `default` = RowingThresholds()

    // MARK: Signal conditioning

    /// Frames of moving average applied to the knee angle before looking for the catch and finish.
    /// At ~30 fps a 3-frame window smooths landmark jitter without blurring the ~100 ms events being
    /// measured — the same value and the same reasoning as `WallBallThresholds.armSmoothingWindow`.
    var kneeSmoothingWindow = 3

    /// Consecutive frames an event must hold before it is accepted, so a single noisy frame cannot
    /// fire it. Matches `WallBallThresholds.armDriveFrames`.
    var confirmationFrames = 2

    // MARK: Segmentation

    /// How far the knee angle must reverse before an extremum is confirmed as the catch or finish.
    ///
    /// Amplitude hysteresis rather than a velocity threshold on purpose: angular rate varies hugely
    /// between a 20 spm and a 32 spm stroke, so a velocity test would need per-athlete calibration
    /// and would false-fire on a pause. An 8° reversal is 8° at any rate. MediaPipe's frame-to-frame
    /// knee jitter is on the order of 1–3°, so this clears the noise while costing only about one
    /// frame of timing accuracy on each event — it is ~6% of the stroke's ~125° sweep.
    var kneeReversalHysteresis: Double = 8

    /// Catch-to-finish knee-angle range below which a candidate is not a stroke. A real stroke
    /// sweeps 120°+; anything under this is fidgeting, adjusting the straps, or reaching for the
    /// monitor.
    var minStrokeKneeRange: Double = 50

    /// A 66 spm ceiling. A flat-out erg sprint tops out near 50 spm, so this rejects noise-doubled
    /// strokes without ever rejecting a real one.
    var minStrokeSeconds: Double = 0.9

    /// A 15 spm floor. A Hyrox athlete does not row below ~18 spm even fading badly, so anything
    /// slower is a rest rather than a stroke. Also the trigger for resetting the state machine
    /// between pieces.
    var maxStrokeSeconds: Double = 4.0

    /// A tracking dropout longer than this discards the stroke it falls in — about 12 frames.
    ///
    /// Rowing has to be stricter about gaps than wall balls is. Three of the four fault families are
    /// timing- or displacement-based, so a silent gap inflates whichever phase it lands in: half a
    /// second lost during the recovery manufactures a beautiful 2:1 ratio, and the same gap in the
    /// drive manufactures a rushed-recovery fault. Deliberately tighter than
    /// `SessionTimeline.stalenessWindow`, which governs whether to *draw* a stale pose; this governs
    /// whether to *report a number*.
    var trackingGapSeconds: Double = 0.4

    /// Net votes required before the athlete's facing direction is latched for the session. About a
    /// third of a second of agreement; the ankle-versus-hip separation is unambiguous, so this only
    /// guards against startup noise.
    var facingConfidenceVotes = 10

    /// Frames of visibility comparison before the near side is latched — half a second, one full
    /// drive phase. Sticky so it cannot flip mid-stroke and inject a discontinuity into the signal.
    var sideVoteFrames = 15

    // MARK: Sequence

    /// How far through the stroke's own catch-to-finish knee range counts as the legs being done.
    ///
    /// Measured against each stroke's own range because rowing has no absolute reference: a 175°
    /// finish for one athlete is 162° for another with tighter hamstrings, and the catch angle
    /// depends on leg length and the foot-stretcher setting.
    ///
    /// Much lower than the 0.9 wall balls uses for the same idea, because **the knee angle is
    /// strongly non-linear in seat position**: as the leg approaches extension the angle changes
    /// far faster per centimetre of slide. On the reference geometry, 0.6 of the angle range is
    /// already about three-quarters of the way down the slide, and 0.85 would be 94% of it — late
    /// enough that any realistic back swing would be flagged as early. Read this as "the legs have
    /// done their work", not "the knee has locked out".
    var legDriveProgress: Double = 0.6

    /// How far the torso must swing back from its catch angle before the back counts as open. A
    /// rigid back still gives a few degrees passively under load; 8° is ~15% of the ~55° total drive
    /// swing — small enough to catch a genuinely early opening, large enough that soft-tissue give
    /// does not trip it.
    var backOpenLeanDelta: Double = 8

    /// How far the elbow must close from its catch angle before the arms count as bent. Arms under
    /// load carry a few degrees of soft elbow, and the total arm draw is ~120°, so 10° is an
    /// unmistakably intentional bend.
    var armBreakAngleDelta: Double = 10

    /// A body segment starting this far *before* the legs finish is a broken kinetic chain.
    ///
    /// Taken from `WallBallThresholds.earlyReleaseOffset` for the same stated reason: ~100 ms is
    /// about three frames at 30 fps, comfortably more than the ~1 frame of lag the smoothing
    /// introduces, and large enough to be a real break rather than a smooth handover.
    ///
    /// There is deliberately **no late equivalent**. Wall balls has `lateReleaseOffset` because a
    /// pause at full extension is a dead spot; rowing's arms finishing last is correct technique,
    /// not a fault.
    var earlySequenceOffset: Double = -0.10

    // MARK: Shooting the slide

    /// Fraction of the seat's total drive travel over which the handle-to-seat ratio is measured.
    ///
    /// Shooting the slide is an early-drive error, and the second half of the drive is legitimately
    /// contaminated by the back swing and the arm draw. Defined by travel rather than by time so a
    /// 24 spm stroke and a 32 spm stroke are compared over the same portion of the slide.
    var slideWindowSeatFraction: Double = 0.5

    /// Handle travel ÷ seat travel below which the seat is running away from the handle.
    ///
    /// With straight arms and a fixed back the handle travels exactly as far as the seat, so a clean
    /// stroke sits at 1.0. At 0.7, 30% of the seat's travel produced no handle movement — visible to
    /// a coach and a real power leak. Generous on purpose: the wrist is the noisiest input to this
    /// measurement.
    var minSlideRatio: Double = 0.7

    /// Seat travel below which the ratio's denominator is noise and the fault is suppressed rather
    /// than reported. A full slide is roughly 1.0–1.3 torso lengths.
    var minSeatTravel: Double = 0.6

    // MARK: Rhythm

    /// Recovery ÷ drive below which the athlete is pulling themselves up the slide.
    ///
    /// The coached target is 2.0 and race-pace rowing sits around 1.6–2.0. Set conservatively at 1.3
    /// because this is the fault an athlete would otherwise hear most often, and the easiest one to
    /// make annoying.
    var minRecoveryRatio: Double = 1.3

    // MARK: Range of motion

    /// Knee angle at the catch above which the athlete never got to full compression. A good catch
    /// sits at 40–50° with vertical shins; 65° allows for ankle-mobility variation between athletes
    /// and for systematic landmark error, while still catching a genuinely short catch, which
    /// typically lands at 80°+.
    var maxCatchKneeAngle: Double = 65

    /// How far past vertical the torso must lay back at the finish. Coached layback is 10–20° (the
    /// eleven-o'clock position), so 10° is the low end of acceptable and only fires on a finish that
    /// is genuinely upright or still leaning forward.
    var minFinishLayback: Double = 10

    /// How far in front of the hips the handle may still be at the finish, in torso lengths. A
    /// complete finish draws it to the lower ribs, around 0.2–0.35 ahead of the hip; 0.45 leaves
    /// headroom for wrist-landmark error and body-shape variation.
    var maxFinishHandleDistance: Double = 0.45

    // MARK: Scale

    /// Confidently tracked torso samples before the scale is trusted — half a second.
    ///
    /// Until then the scale-dependent faults are suppressed, which means the first stroke of a
    /// session may report fewer faults than a later identical one. That is correct behaviour: the
    /// alternative is measuring against a half-formed mean.
    var minScaleSamples = 15

    /// Fractional deviation from the running mean beyond which a torso sample is rejected. Wide,
    /// because it exists to reject frames where the pose collapsed entirely rather than to reject
    /// genuine variation.
    var scaleOutlierTolerance: Double = 0.5

    // MARK: Viewpoint

    /// Where the camera-angle classification divides.
    ///
    /// A seated rower's shoulder-to-torso ratio drifts upward at the catch — the torso compresses
    /// and the shoulders roll forward — pushing the reading from `.sideOn` toward `.angled`.
    /// `supportsReachMeasurement` accepts both, so horizontal measurements survive; it is the reason
    /// the analyzer takes the *modal* viewpoint over a session rather than latching the most recent
    /// one the way `WallBallRepAnalyzer` does.
    var viewpoint = ViewpointThresholds.default
}
