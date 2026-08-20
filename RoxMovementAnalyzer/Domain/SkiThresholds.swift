import Foundation

/// Every tunable constant behind SkiErg analysis, in one place.
///
/// **These are informed starting estimates, not calibrated values.** No SkiErg footage has been
/// measured against them. Angles are in degrees, times in seconds, and distances in torso lengths
/// (the session-level scale from `ScaleReference`) so they do not change with the athlete's distance
/// from the camera.
///
/// Analysis assumes the athlete is filmed **side-on**, which is what makes the sagittal plane
/// parallel to the image plane and both the hinge and the arm sweep honest. Horizontal measurements
/// are suppressed when the viewpoint says otherwise.
struct SkiThresholds: Equatable {
    static let `default` = SkiThresholds()

    // MARK: Signal conditioning

    /// Frames of moving average applied to the shoulder angle before looking for the catch and the
    /// finish. Same value and same reasoning as `RowingThresholds.kneeSmoothingWindow`: at ~30 fps a
    /// 3-frame window smooths landmark jitter without blurring the ~100 ms events being measured.
    var shoulderSmoothingWindow = 3

    /// Consecutive frames an event must hold before it is accepted, so a single noisy frame cannot
    /// fire it.
    var confirmationFrames = 2

    // MARK: Segmentation

    /// How far the shoulder angle must reverse before an extremum is confirmed as the catch or the
    /// finish.
    ///
    /// Amplitude hysteresis rather than a velocity threshold, for the reason
    /// `RowingThresholds.kneeReversalHysteresis` sets out: 8° is 8° whether the athlete is pulling at
    /// 40 or 60 a minute, whereas angular rate would need per-athlete calibration. It clears
    /// MediaPipe's 1–3° of joint jitter at a cost of about one frame of timing accuracy on each
    /// event, and it is ~6% of the pull's ~130° sweep.
    var shoulderReversalHysteresis: Double = 8

    /// Catch-to-finish shoulder-angle range below which a candidate is not a pull. A real pull sweeps
    /// 120°+ from arms overhead to hands past the hips; anything under this is the athlete settling
    /// into position or reaching for the monitor.
    var minPullShoulderRange: Double = 60

    /// A 100 ppm ceiling. A flat-out SkiErg sprint tops out near 70 pulls a minute, so this rejects
    /// noise-doubled pulls without ever rejecting a real one.
    var minPullSeconds: Double = 0.6

    /// A 20 ppm floor. A Hyrox athlete holds 40–50 on the ski even fading badly, so anything slower is
    /// a rest rather than a pull. Also the trigger for resetting the state machine between pieces.
    var maxPullSeconds: Double = 3.0

    /// A tracking dropout longer than this discards the pull it falls in — about 12 frames.
    ///
    /// As strict as rowing, and for the same reason: the sequence and rhythm faults are timing-based,
    /// so a silent gap inflates whichever phase it lands in and manufactures a fault that never
    /// happened. Deliberately tighter than `SessionTimeline.stalenessWindow`, which governs whether to
    /// *draw* a stale pose; this governs whether to *report a number*.
    var trackingGapSeconds: Double = 0.4

    /// Net votes required before the athlete's facing direction is latched for the session — about a
    /// third of a second of agreement. Both votes behind it are fixed anatomy rather than stroke
    /// phase, so this only guards against startup noise.
    var facingConfidenceVotes = 10

    /// Frames of visibility comparison before the near side is latched — half a second. Sticky so it
    /// cannot flip mid-pull and inject a discontinuity into the signal.
    var sideVoteFrames = 15

    // MARK: Hinge

    /// How far the torso must lean forward at the finish. A hinge-led pull folds to 45–55°, so 35° is
    /// the low end of acceptable and only fires on a pull taken standing near-upright.
    ///
    /// This is the gate for **both** hinge faults: the ratio below only chooses which cue the athlete
    /// gets once the hinge is already known to be short.
    var minFinishLean: Double = 35

    /// Forward torso swing ÷ knee flexion over the drive, below which the legs are doing the hinge's
    /// work.
    ///
    /// A hinge-led pull folds 45–55° at the waist while the knees only soften by 25–35°, so it sits
    /// comfortably above 1; a squatted pull inverts that. Set low on purpose: it only ever fires
    /// alongside a short finish lean, so it is choosing *which* cue to give rather than deciding
    /// whether anything was wrong.
    var minHingeToKneeRatio: Double = 0.7

    /// Knee flexion below which the substitution ratio's denominator is noise, and the plain
    /// range-of-motion fault is reported instead. A pull that barely bends the knees is not a squat,
    /// whatever the ratio says.
    var minKneeFlexionForRatio: Double = 5

    // MARK: Force curve

    /// The force proxy, and why it is honest.
    ///
    /// A SkiErg is an **air-braked flywheel**, so handle force is `A·a(t) + B·v(t)²` — an inertial term
    /// spinning the wheel up, and a drag term. Both are computable from the hand path, which is already
    /// tracked. `A` and `B` are unknown to us (they depend on the damper setting and the sprocket), but
    /// they are per-machine constants, and every check below is a **ratio taken within a single pull**,
    /// so the unknown gain cancels out completely.
    ///
    /// The `A·a` term is dropped: differentiating MediaPipe wrists twice is mostly noise. What is left
    /// is hand speed, monotonic in the drag term and needing no constants at all. It is a proxy for the
    /// curve's *shape and timing* — never for newtons, which is why nothing here reports a force.

    /// Frames of moving average applied to the hand-speed series before the peak is located. Speed is
    /// already a central difference, which smooths once; this takes the remaining wrist jitter off
    /// without blurring a peak that sits inside a ~500 ms drive.
    var handSpeedSmoothingWindow = 3

    /// Peak hand speed, in torso lengths per second, below which the curve is noise rather than a pull
    /// and all three force-curve checks are suppressed.
    ///
    /// A pull moves the hands roughly 1.5 torso lengths in half a second, so a real one peaks well
    /// above 3. This sits far below that: it exists to reject a pull tracked so badly that the speed
    /// series is jitter, not to judge how hard the athlete worked — that is the athlete's business.
    var minPeakHandSpeed: Double = 0.8

    /// The opening share of the pull's own sweep over which top-end loading is *reported*.
    ///
    /// A metric, not a fault threshold. It was going to carry a `lateEngagement` check, but measured
    /// across the fixture at window widths from 0.10 to 0.35 it tracked `maxPeakDriveFraction`
    /// monotonically every time — the same defect from the other end, not a second one. It is still
    /// worth showing the athlete, so it is computed and displayed and nothing is judged on it.
    var catchConnectionSweepFraction: Double = 0.25

    /// Where peak hand speed may sit within the drive, as a fraction from catch to finish.
    ///
    /// A body-driven pull front-loads: the compression puts the peak in the first third. A pull
    /// finished by the arms puts it late. 0.55 sits just past the midpoint, so it fires only on a
    /// genuinely back-loaded curve rather than on a broad, flat-topped one.
    var maxPeakDriveFraction: Double = 0.55

    /// How large a second peak must be, as a share of the largest, before the drive counts as having
    /// two efforts rather than one with a ripple in it.
    var disconnectSecondPeakFraction: Double = 0.6

    /// The trough between two peaks, as a share of the smaller of them, below which the drive is two
    /// separate efforts. Conservative on purpose: a real double-hump on a SkiErg is unmistakable, and
    /// wrist noise can manufacture a shallow dip in anything.
    var maxMidDriveDip: Double = 0.7

    // MARK: Scale

    /// Confidently tracked torso samples before the scale is trusted — half a second.
    ///
    /// Until then the scale-dependent faults are suppressed, which means the first pull of a session
    /// may report fewer faults than a later identical one. That is correct behaviour: the alternative
    /// is measuring against a half-formed mean.
    var minScaleSamples = 15

    /// Fractional deviation from the running mean beyond which a torso sample is rejected. Wide,
    /// because it exists to reject frames where the pose collapsed entirely rather than to reject
    /// genuine variation.
    var scaleOutlierTolerance: Double = 0.5

    // MARK: Viewpoint

    /// Where the camera-angle classification divides.
    ///
    /// A standing athlete's shoulder-to-torso ratio is steadier than a seated rower's, but the
    /// overhead reach still rolls the shoulders forward and shortens the apparent torso, which pushes
    /// the reading from `.sideOn` toward `.angled`. `supportsReachMeasurement` accepts both, and the
    /// analyzer takes the *modal* viewpoint over the session rather than the most recent value.
    var viewpoint = ViewpointThresholds.default
}
