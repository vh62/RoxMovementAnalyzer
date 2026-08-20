import Foundation

/// Measurements of an athlete performing burpee broad jumps, filmed side-on.
///
/// These live apart from `PoseMeasurements` for the same reason the rowing ones do: every measurement
/// below needs the athlete's facing direction, a session-level scale, or the assumption that the
/// athlete is travelling across the frame rather than staying put.
///
/// **Facing comes from `standingFacingVote`**, shared with the SkiErg rather than reimplemented. Both
/// of its votes are fixed anatomy — the toes point the way the athlete travels and the face looks that
/// way too — so neither flips between standing and prone, which is exactly the property this station
/// needs. `facingVote`, the rowing one, is anchored on the feet being in front of the hips and is
/// wrong here: a burpee puts the feet behind the hips for most of every rep.
///
/// **Everything vertical is referenced to the ankle, not to a floor line.** A floor plane would have to
/// be estimated, and this is the one station where the athlete travels across the frame — perspective
/// makes the floor's image height drift with x, so a session-wide floor estimate slowly goes wrong. A
/// difference taken against the athlete's own ankle in the same frame has no such error, and needs
/// nothing estimated. The same reasoning `PoseMeasurements.shoulderAngle` gives for measuring against
/// the torso rather than against vertical.
extension PoseFrame {
    /// How far the shoulders sit above the feet, in torso lengths — the segmentation signal.
    ///
    /// Roughly 2.2 standing, where the shoulder sits a torso plus a leg above the ankle, and near 0 at
    /// the bottom of a burpee, where the athlete is prone and both are on the deck. That range is wide
    /// enough that segmentation never needs a floor model.
    ///
    /// Filmed side-on the torso is in the image plane at both ends of that range — vertical standing,
    /// horizontal lying down — so the per-frame torso length is honest throughout and this does not
    /// need to wait for the session scale to settle. That matters: a signal gated on `ScaleReference`
    /// would go blind for the first half-second of every session.
    var chestHeightAboveFeet: Double? {
        guard let shoulder = visibleCenter(.leftShoulder, .rightShoulder),
              let ankle = visibleCenter(.leftAnkle, .rightAnkle),
              let torso = sagittalTorsoLength else { return nil }

        // y increases downward, so a shoulder above the ankle gives a positive value.
        return (ankle.y - shoulder.y) / torso
    }

    /// How far the hands sit above the feet, in torso lengths — the hands-on-the-deck test.
    ///
    /// Near 0 with the hands planted, and around 1 standing, where the wrists hang at hip height. Both
    /// corridor rules only mean anything while the hands are actually down, so this is what gates them.
    var handHeightAboveFeet: Double? {
        guard let wrist = visibleCenter(.leftWrist, .rightWrist),
              let ankle = visibleCenter(.leftAnkle, .rightAnkle),
              let torso = sagittalTorsoLength else { return nil }

        return (ankle.y - wrist.y) / torso
    }

    /// How far the front toe sits beyond the fingertips along the forward axis, in scale units.
    /// Positive is rule 5's violation — the feet have come up past the hands.
    ///
    /// Compares landmark against landmark, `.leftFootIndex`/`.rightFootIndex` against
    /// `.leftIndex`/`.rightIndex`, so **the rule needs no centimetre conversion**. Rule 5 draws its
    /// line at the fingertips themselves, and MediaPipe reports the fingertips, so unlike rule 6 there
    /// is no real-world length to assume. The scale here only turns the overshoot into a reportable
    /// number; the sign that decides the fault does not depend on it.
    func toeBeyondFingertips(facing: Facing, scale: Double) -> Double? {
        guard scale > 0,
              let toe = frontMost(.leftFootIndex, .rightFootIndex, facing: facing),
              let fingertip = frontMost(.leftIndex, .rightIndex, facing: facing) else { return nil }

        return facing.sign * (toe.x - fingertip.x) / scale
    }

    /// How far the wrists sit ahead of the front toe along the forward axis, in scale units.
    /// Rule 6 caps this at 30 cm.
    ///
    /// Measured from the wrist rather than the fingertip because rule 5a pins the 30 cm to "the base of
    /// the racer's palms where their hands meet their wrists" — a different landmark from the one rule
    /// 5 uses, which is why these are two measurements rather than one signed scalar read twice.
    func handsAheadOfFrontToe(facing: Facing, scale: Double) -> Double? {
        guard scale > 0,
              let wrist = visibleCenter(.leftWrist, .rightWrist),
              let toe = frontMost(.leftFootIndex, .rightFootIndex, facing: facing) else { return nil }

        return facing.sign * (wrist.x - toe.x) / scale
    }

    /// Where the athlete is along their direction of travel, in scale units — the trace the broad
    /// jump is measured from.
    ///
    /// Ankle-centred rather than hip-centred because the jump is what the feet did: a hip that drifts
    /// while the feet stay planted is a lean, not travel.
    func travelPosition(facing: Facing, scale: Double) -> Double? {
        guard scale > 0, let ankle = visibleCenter(.leftAnkle, .rightAnkle) else { return nil }
        return facing.sign * ankle.x / scale
    }

    /// The more forward of a left/right pair along the athlete's forward axis, using only tracked
    /// joints.
    ///
    /// Rule 6 says "the front foot" explicitly, and rule 5 is breached by whichever hand or foot
    /// crosses the line first, so both rules want the extreme rather than the centre — the opposite of
    /// what `visibleCenter` gives. Falls back to whichever single joint is tracked, because side-on the
    /// far one is behind the near one and comes back as an estimate rather than a measurement.
    private func frontMost(
        _ first: PoseLandmarkName,
        _ second: PoseLandmarkName,
        facing: Facing
    ) -> (x: Double, y: Double)? {
        let points = [first, second].compactMap { landmark($0) }.filter(\.isVisible)
        guard let leading = points.max(by: { facing.sign * $0.x < facing.sign * $1.x }) else {
            return nil
        }
        return (x: leading.x, y: leading.y)
    }
}
