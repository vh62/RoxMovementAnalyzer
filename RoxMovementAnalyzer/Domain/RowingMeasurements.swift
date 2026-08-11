import Foundation

/// Which way the athlete faces the flywheel, in image terms.
///
/// A rower can be filmed from either side of the erg, and the front camera mirrors the picture, so
/// "forward" cannot be assumed — it is derived from the pose (see `PoseFrame.facingVote`) and every
/// horizontal rowing measurement is multiplied by `sign` to become athlete-relative.
enum Facing: Equatable {
    /// The athlete faces screen-left; forward is decreasing x.
    case left
    /// The athlete faces screen-right; forward is increasing x.
    case right

    var sign: Double { self == .right ? 1 : -1 }
}

/// Session-level length scale for normalising rowing distances.
///
/// Rowing does not use per-frame `torsoLength` the way wall balls does. For a seated athlete that
/// value fluctuates most at exactly the moment the measurements matter — at the catch the shoulders
/// roll forward and the hip landmark, which MediaPipe places at the greater trochanter, disappears
/// under the thigh. The athlete's torso does not change length during a piece, so a running mean
/// over well-tracked frames is strictly more honest than a value re-measured every frame.
struct ScaleReference: Equatable {
    /// Confidently tracked samples required before the scale is trusted at all.
    var minimumSamples: Int
    /// Fractional deviation from the running mean beyond which a sample is discarded. Wide on
    /// purpose: this exists to reject frames where the pose collapsed, not genuine variation.
    var outlierTolerance: Double

    private var total: Double = 0
    private var count: Int = 0

    init(minimumSamples: Int, outlierTolerance: Double) {
        self.minimumSamples = minimumSamples
        self.outlierTolerance = outlierTolerance
    }

    /// The scale, or nil until enough samples have been seen. Callers must suppress scale-dependent
    /// measurements while this is nil rather than guessing — that is why it is optional.
    var value: Double? {
        count >= minimumSamples ? runningMean : nil
    }

    private var runningMean: Double? {
        count > 0 ? total / Double(count) : nil
    }

    mutating func observe(_ sample: Double) {
        guard sample > 0 else { return }

        // Only reject outliers once there is a mean worth trusting, otherwise the first few
        // samples would gate each other.
        if count >= minimumSamples, let mean = runningMean,
           abs(sample - mean) / mean > outlierTolerance {
            return
        }

        total += sample
        count += 1
    }
}

/// Measurements of an athlete seated on a rowing machine, filmed side-on.
///
/// These live apart from `PoseMeasurements` because every one of them needs something that file
/// deliberately does not take: the athlete's facing direction, a session-level scale, or the
/// assumption that the athlete is seated on a rail with their feet strapped down.
///
/// The wrists stand in for the handle throughout. The pose model has no concept of the handle, but
/// the hands are on it while it is being pulled — the same substitution `WallBallFault` documents
/// for the ball, and for the same reason: the faults are then phrased in terms of what the body
/// did, which is what the athlete can change.
extension PoseFrame {
    /// This frame's evidence for which way the athlete faces, as a signed tally.
    ///
    /// Anchored on the fact that **the feet are always in front of the hips**: they are strapped to
    /// the footplate and the seat never travels past it. That holds at every point in the stroke,
    /// and by the widest margin at the finish. The knee vote says the same thing for a seated
    /// athlete and costs nothing, so it is included as corroboration — it survives the ankle
    /// dropping out behind the foot straps, which is a real risk on an erg.
    var facingVote: Int {
        guard let hip = visibleCenter(.leftHip, .rightHip) else { return 0 }

        var vote = 0
        if let ankle = visibleCenter(.leftAnkle, .rightAnkle) {
            vote += ankle.x > hip.x ? 1 : -1
        }
        if let knee = visibleCenter(.leftKnee, .rightKnee) {
            vote += knee.x > hip.x ? 1 : -1
        }
        return vote
    }

    /// This frame's verdict on its own, for tests and diagnostics. The analyzer tallies votes across
    /// frames instead — a single flickering frame that mirrored one sample's measurements would read
    /// as a violent handle reversal mid-stroke.
    var facing: Facing? {
        let vote = facingVote
        guard vote != 0 else { return nil }
        return vote > 0 ? .right : .left
    }

    /// Torso angle from vertical in degrees, **positive when leaning toward the flywheel**.
    ///
    /// Roughly +30° at the catch, through vertical during the drive, to −20° or so at the finish,
    /// where the negative value is the layback.
    func forwardTorsoLean(facing: Facing) -> Double? {
        guard let hip = visibleCenter(.leftHip, .rightHip),
              let shoulder = visibleCenter(.leftShoulder, .rightShoulder),
              let raw = PoseGeometry.signedAngleFromVertical(
                  fromX: hip.x, fromY: hip.y, toX: shoulder.x, toY: shoulder.y
              ) else { return nil }

        return raw * facing.sign
    }

    /// Footplate-to-seat distance along the forward axis, in scale units. Grows through the drive as
    /// the seat travels away from the feet.
    ///
    /// Measured from the ankle rather than from a fixed image position because the feet are strapped
    /// down: the ankle is the one point on the athlete that does not move, which makes this
    /// difference immune to the phone drifting.
    func seatOffset(facing: Facing, scale: Double) -> Double? {
        guard scale > 0,
              let hip = visibleCenter(.leftHip, .rightHip),
              let ankle = visibleCenter(.leftAnkle, .rightAnkle) else { return nil }

        return facing.sign * (ankle.x - hip.x) / scale
    }

    /// Footplate-to-handle distance along the forward axis, in scale units. Grows through the drive.
    func handleOffset(facing: Facing, scale: Double) -> Double? {
        guard scale > 0,
              let wrist = visibleCenter(.leftWrist, .rightWrist),
              let ankle = visibleCenter(.leftAnkle, .rightAnkle) else { return nil }

        return facing.sign * (ankle.x - wrist.x) / scale
    }

    /// How far in front of the hips the handle still is, in scale units. Small at a complete finish,
    /// where the handle is drawn in to the lower ribs.
    ///
    /// Referenced to the hip rather than the shoulder deliberately: at the finish the shoulder is
    /// itself travelling backward, so a shoulder-relative measure would fold the layback into the
    /// handle draw and stop being able to tell the two errors apart.
    func handleAheadOfHips(facing: Facing, scale: Double) -> Double? {
        guard scale > 0,
              let wrist = visibleCenter(.leftWrist, .rightWrist),
              let hip = visibleCenter(.leftHip, .rightHip) else { return nil }

        return facing.sign * (wrist.x - hip.x) / scale
    }

    /// Shoulder-centre to hip-centre distance from **visible joints only** — the scale sample.
    ///
    /// A deliberate parallel to `torsoLength` rather than a replacement for it: that one is built
    /// from `midpoint`, which averages in the occluded far joint, and five wall-ball measurements
    /// depend on its exact behaviour. Changing it is a separate job.
    var sagittalTorsoLength: Double? {
        guard let shoulder = visibleCenter(.leftShoulder, .rightShoulder),
              let hip = visibleCenter(.leftHip, .rightHip) else { return nil }

        let length = hypot(shoulder.x - hip.x, shoulder.y - hip.y)
        return length > 0.01 ? length : nil
    }

    /// Knee-to-ankle distance on one side.
    ///
    /// Carried alongside the torso sample purely to settle which makes the better scale reference on
    /// real footage. The near shin is the most consistently visible rigid segment on an erg, and
    /// unlike the torso it has no landmark sitting on the seat under a thigh. Compare the two
    /// coefficients of variation over a real session; swapping is a one-line change because
    /// everything divides by a single scale.
    func shinLength(_ side: BodySide) -> Double? {
        guard let knee = landmark(side.knee), let ankle = landmark(side.ankle),
              knee.isVisible, ankle.isVisible else { return nil }

        let length = hypot(knee.x - ankle.x, knee.y - ankle.y)
        return length > 0.01 ? length : nil
    }
}
