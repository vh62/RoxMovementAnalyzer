import Foundation

/// Every tunable constant behind wall-ball analysis, in one place.
///
/// These are informed starting estimates, not calibrated values. Distances are expressed in
/// torso lengths (shoulder centre → hip centre) so they do not change with the athlete's
/// distance from the camera; times are in seconds.
///
/// Use the tuning readout in live analysis and playback to compare these against real footage
/// — reps you judge good or bad by eye — and set them from what you actually measure.
struct WallBallThresholds: Equatable {
    static let `default` = WallBallThresholds()

    // MARK: Depth (hip vs knee, normalized image coordinates, y increases downward)

    /// Hips this far above the knees counts as standing / top of the rep.
    var standingDelta = -0.12
    /// Hips dropped past this counts as having started a squat attempt.
    var descentDelta = -0.06
    /// Hip at or below the knee — legal HYROX depth.
    var validDepthDelta = 0.0

    // MARK: Leg drive

    /// How far back toward standing the hips must travel, as a fraction of that rep's own descent,
    /// to count as full leg extension.
    ///
    /// Measured from hip-vs-knee height rather than the knee angle: from a front-on view the knee
    /// travels forward in depth rather than across the image, so the knee angle barely changes and
    /// would report full extension throughout the squat.
    var legExtensionProgress: Double = 0.9

    // MARK: Arm drive / release

    /// Frames of moving average applied to arm height before looking for onset and peak. At
    /// ~30 fps a 3-frame window smooths jitter without blurring the ~100 ms events we measure.
    var armSmoothingWindow = 3
    /// Rise in arm height (torso lengths per second) that counts as the arms actively driving.
    var armDriveVelocity: Double = 0.6
    /// Consecutive frames above `armDriveVelocity` required before the drive is considered started,
    /// so a single noisy frame cannot trigger it.
    var armDriveFrames = 2
    /// How far above the shoulders the hands must finish, in torso lengths, for the movement to be
    /// treated as a throw. Guards against reading the descent — where the shoulders drop toward
    /// hands carried at chest height — as an arm drive.
    var minReleaseArmHeight: Double = 0.15

    /// Arms starting this far *before* the legs finish extending is an early release — the
    /// kinetic chain is broken and the throw is being powered by the arms.
    ///
    /// ~100 ms is about three frames at 30 fps: comfortably more than the ~1 frame of lag the
    /// smoothing introduces, and large enough to be a real break rather than a smooth handover.
    var earlyReleaseOffset: Double = -0.10
    /// Arms starting this far *after* full leg extension is a dead spot — the drive's momentum
    /// has been lost before the ball is thrown.
    var lateReleaseOffset: Double = 0.15

    // MARK: Catch

    /// Horizontal wrist-to-shoulder distance at the catch, in torso lengths, beyond which the
    /// ball is being received too far in front of the body.
    var catchReachLimit: Double = 0.55

    // MARK: Viewpoint

    /// Shoulder width ÷ torso length below this reads as a side-on view.
    var sideOnRatio: Double = 0.5
    /// Shoulder width ÷ torso length above this reads as a front-on view.
    var frontOnRatio: Double = 0.8
}
