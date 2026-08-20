import Foundation

/// Every tunable constant behind burpee broad jump analysis, in one place.
///
/// **These are informed starting estimates, not calibrated values.** No burpee footage has been
/// measured against them. Times are in seconds and distances in torso lengths — either the per-frame
/// `sagittalTorsoLength` for the segmentation signal, or the session-level `ScaleReference` for the
/// rule measurements — so nothing changes with the athlete's distance from the camera.
///
/// Two of these thresholds are different in kind from anything else in the app, and both are called
/// out where they appear: `maxHandsAheadOfFrontToe` converts a **real-world 30 cm** from the rulebook
/// into torso lengths, and so carries an assumed torso length; and `feetPastFingertipsMargin` exists
/// only because rule 5 draws its line at zero, where landmark jitter alone would decide half the
/// verdicts.
///
/// Analysis assumes the athlete is filmed **side-on and perpendicular to the direction of travel**,
/// which is what puts the hand/foot corridor in the image plane. Every implemented rule is sagittal.
/// Several clauses of §8.4 are deliberately not checked at all, including the 5 cm foot stagger and
/// the ban on extra steps; `BurpeeFault` carries the reason for each.
struct BurpeeThresholds: Equatable {
    static let `default` = BurpeeThresholds()

    // MARK: Signal conditioning

    /// Frames of moving average applied to the chest-height signal before looking for the bottom and
    /// the top. Same value and reasoning as `SkiThresholds.shoulderSmoothingWindow`: at ~30 fps a
    /// 3-frame window takes off landmark jitter without blurring the events being measured.
    var chestSmoothingWindow = 3

    /// Consecutive frames an event must hold before it is accepted, so one noisy frame cannot fire it.
    var confirmationFrames = 2

    // MARK: Segmentation

    /// How far the chest-height signal must reverse before an extremum is confirmed as the bottom or
    /// the top, in torso lengths.
    ///
    /// Amplitude hysteresis rather than a velocity threshold, for the reason
    /// `SkiThresholds.shoulderReversalHysteresis` sets out. A burpee sweeps roughly 2.0 torso lengths
    /// from prone to standing, so 0.25 is about 12% of the range — comfortably clear of jitter, and far
    /// short of anything that would merge two reps.
    var chestReversalHysteresis: Double = 0.25

    /// Bottom-to-top chest-height range below which a candidate is not a burpee, in torso lengths.
    ///
    /// A real rep runs from about 0.2 prone to about 2.2 standing. 1.2 rejects an athlete bobbing at
    /// the top or setting up, while still accepting a badly executed rep that never gets fully down —
    /// which must be **counted and faulted**, not discarded, or the analyzer falls silent on the very
    /// thing `chestNotDown` exists to catch.
    var minChestRange: Double = 1.2

    /// A rep this fast is noise, not a burpee broad jump. Even an elite athlete takes about two
    /// seconds a rep, so this rejects doubled detections without ever rejecting a real rep.
    var minRepSeconds: Double = 1.0

    /// A rep this slow is a rest, not a rep. A badly fading athlete is still under five seconds, so
    /// this only fires on someone who has stopped. Also the trigger for resetting the state machine.
    var maxRepSeconds: Double = 8.0

    /// A tracking dropout longer than this discards the rep it falls in — about 12 frames.
    ///
    /// As strict as the ergs, for a related but distinct reason: the corridor rules are read at a
    /// specific instant within the rep, so a silent gap can hide the exact frames where the feet were
    /// furthest forward and turn a no-rep into a clean one.
    var trackingGapSeconds: Double = 0.4

    /// Net votes required before the athlete's facing is latched — about a third of a second. Both
    /// votes behind `standingFacingVote` are fixed anatomy, so this only guards startup noise.
    var facingConfidenceVotes = 10

    /// Frames of visibility comparison before the near side is latched — half a second.
    var sideVoteFrames = 15

    // MARK: Rule 2a and 7 — chest on the ground

    /// Chest height at the bottom, in torso lengths, at or below which contact is credited.
    ///
    /// The rulebook defines contact as the nipple line clearly touching, and there is deliberately no
    /// thigh requirement — that is a CrossFit standard, not this one. Lying prone the shoulder centre
    /// still sits about a quarter of a torso above the ankle, on chest depth alone, so zero is the
    /// wrong line.
    ///
    /// Set generously on purpose. This threshold calls a **no-rep**, and the cost of the two errors is
    /// not symmetric: telling an athlete a good rep did not count is worse than missing a marginal bad
    /// one, so it errs toward crediting contact.
    var maxChestContactHeight: Double = 0.35

    // MARK: Rules 5 and 6 — the hand/foot corridor

    /// Hand height above the feet, in torso lengths, below which the hands count as planted.
    ///
    /// Both corridor rules only mean anything while the hands are actually on the deck, so this gates
    /// both — and it bounds the broad jump too, which is the travel taken with the hands *off* it.
    /// Standing, the wrists hang near hip height at about 1.0; planted they are level with the feet.
    /// 0.35 sits well clear of both.
    ///
    /// This is also where rules 3 and 7 are honoured rather than checked: both permit stepping freely
    /// into and out of the burpee, and "into and out of the burpee" means the hands are already down,
    /// so travel taken below this height is the athlete's own business.
    var handsDownHeight: Double = 0.35

    /// How far past the fingertips the front toe may reach before rule 5 is called, in torso lengths.
    ///
    /// The rule itself draws the line at exactly zero. A zero threshold cannot be judged from pose:
    /// the fingertip and toe landmarks are the jitteriest points BlazePose produces, so a rep sitting
    /// on the line would have its verdict decided by noise. 0.1 torso lengths is roughly 5 cm of
    /// benefit of the doubt, for the same asymmetry `maxChestContactHeight` documents.
    var feetPastFingertipsMargin: Double = 0.1

    /// How far ahead of the front toe the wrists may sit when the hands are planted, in torso lengths.
    ///
    /// **This is the app's first absolute-distance threshold.** Rule 6 caps it at 30 cm and rule 5a
    /// measures that from the base of the palm. Every other threshold in the app is a ratio or an
    /// angle and needs no real-world length; this one does, so it carries an assumption: an adult
    /// shoulder-to-hip torso of roughly 50 cm, giving 30 ÷ 50 ≈ 0.6.
    ///
    /// That assumption is the least defensible number in this file, and it scales the wrong way — a
    /// tall athlete has a long torso and gets a larger real-world allowance than the rulebook grants.
    /// Athlete height is the obvious calibration input and would remove the estimate entirely.
    var maxHandsAheadOfFrontToe: Double = 0.6

    // MARK: Scale

    /// Confidently tracked torso samples before the scale is trusted — half a second.
    ///
    /// Until then the corridor rules are suppressed, so the first rep of a session may report fewer
    /// faults than a later identical one. That is correct: the alternative is judging a no-rep
    /// against a half-formed mean.
    var minScaleSamples = 15

    /// Fractional deviation from the running mean beyond which a torso sample is rejected. Wide,
    /// because it exists to reject frames where the pose collapsed rather than genuine variation.
    var scaleOutlierTolerance: Double = 0.5

    // MARK: Viewpoint

    /// Where the camera-angle classification divides.
    ///
    /// The athlete spends part of every rep prone, where the shoulders foreshorten differently than
    /// they do standing, so the per-frame reading swings more than at any other station. The analyzer
    /// takes the **modal** viewpoint over the session rather than the most recent value.
    var viewpoint = ViewpointThresholds.default
}
