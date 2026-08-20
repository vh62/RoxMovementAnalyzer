import Foundation

/// Measurements of an athlete standing at a SkiErg, filmed side-on.
///
/// Deliberately thin. Most of what a SkiErg pull needs already exists and is shared rather than
/// reimplemented: `Facing` and `ScaleReference` for the forward axis and the length scale,
/// `forwardTorsoLean(facing:)` for the hinge, `handleAheadOfHips(facing:scale:)` for the handle draw
/// (the SkiErg has handles too, and the wrists stand in for them the same way), `sagittalTorsoLength`
/// for the scale sample, and `kneeAngle` / `elbowAngle` / `shoulderAngle` for the joints. Only the two
/// measurements below are genuinely specific to a standing athlete on this machine.
extension PoseFrame {
    /// This frame's evidence for which way the athlete faces, as a signed tally.
    ///
    /// Separate from `facingVote` because that one is anchored on the feet being in front of the hips
    /// — true of a rower strapped to a footplate, and false of an athlete standing upright, where the
    /// ankles sit under the hips and the hinge pushes the hips *behind* the feet.
    ///
    /// Both votes here are **fixed anatomy rather than stroke phase**, so neither can flip mid-pull:
    /// the toes point toward the machine and the face looks at it from the first frame to the last. A
    /// wrist-based vote would be unusable for exactly that reason — the hands are ahead of the body at
    /// the catch and behind it at the finish, so it would reverse every pull.
    var standingFacingVote: Int {
        var vote = 0

        if let nose = landmark(.nose), nose.isVisible,
           let ear = visibleCenter(.leftEar, .rightEar) {
            vote += nose.x > ear.x ? 1 : -1
        }

        if let toe = visibleCenter(.leftFootIndex, .rightFootIndex),
           let heel = visibleCenter(.leftHeel, .rightHeel) {
            vote += toe.x > heel.x ? 1 : -1
        }

        return vote
    }

    /// This frame's verdict on its own, for tests and diagnostics. The analyzer tallies votes across
    /// frames instead, so a single flickering frame cannot mirror one sample's measurements.
    var standingFacing: Facing? {
        let vote = standingFacingVote
        guard vote != 0 else { return nil }
        return vote > 0 ? .right : .left
    }

    /// The hands' position relative to the feet, in scale units, along the athlete's forward axis and
    /// vertically. The input to the force curve.
    ///
    /// Anchored on the ankle rather than on a fixed image position for the reason
    /// `RowingMeasurements.seatOffset` gives: the feet are the one part of the athlete that does not
    /// move, so a difference measured from them is immune to the phone drifting. That matters far more
    /// here than for a static reading, because the force proxy differentiates this — a slow camera
    /// drift would otherwise read as a steady handle force that is not there.
    ///
    /// Returns a point rather than a distance because the hands travel a curved path — down and back —
    /// and the speed along it is what the flywheel sees.
    func handOffsetFromFeet(facing: Facing, scale: Double) -> (x: Double, y: Double)? {
        guard scale > 0,
              let wrist = visibleCenter(.leftWrist, .rightWrist),
              let ankle = visibleCenter(.leftAnkle, .rightAnkle) else { return nil }

        return (
            x: facing.sign * (wrist.x - ankle.x) / scale,
            y: (ankle.y - wrist.y) / scale
        )
    }
}
