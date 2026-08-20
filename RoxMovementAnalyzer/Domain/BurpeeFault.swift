import Foundation

/// A rule violation on a single burpee broad jump, as judged by §8.4 of the Hyrox rulebook.
///
/// **Every case here is a no-rep, not an inefficiency.** That makes this set different in kind from
/// `SkiFault` and `RowingFault`, where the machine logs the metres whatever the movement looked like,
/// and stricter than `WallBallFault`, where only `shallowDepth` is a rule. A `BurpeeRep` counts if and
/// only if this array is empty.
///
/// Derived from body kinematics, as everywhere else: the pose model cannot see the start line, the
/// lane markings or the judge, so every check is phrased in terms of where the athlete's own hands and
/// feet were relative to each other.
///
/// **Three checks, and the rulebook is mostly a list of things not to check.** Six clauses are
/// deliberately unimplemented, and all but the last are a mistake a general-purpose burpee checker
/// would make:
///
/// - **No foot-stagger check**, though rule 3 caps it at 5 cm on both take-off and landing. 5 cm is
///   about 0.1 torso lengths, below MediaPipe's foot-landmark jitter at 30 fps — and side-on the far
///   ankle is occluded at exactly the moment the feet separate. Reporting it would produce a
///   precise-looking number that is wrong, which is what `PoseMeasurements` exists to refuse.
/// - **No "that was a step, not a jump" check.** Rules 3 and 7 permit the athlete to jump *or step*
///   out of and back into the burpee. Only the broad jump itself must leave the ground, and an athlete
///   who fails that has not travelled, so they simply run out of reps rather than earning a no-rep.
/// - **No knee-contact check.** Rule 4 explicitly permits using a knee coming out of the bottom.
///   Flagging it would fault legal technique.
/// - **No thigh-contact check.** Rule 2a defines chest contact as the nipple line touching. The
///   chest-and-thighs standard is CrossFit's, not this one.
/// - **No short-jump check.** Rule 9: "the length of each broad jump is up to the racer." Jump
///   distance is reported as a metric, because it decides how many reps 80 m costs, but it can never
///   be a fault.
/// - **No extra-steps check**, though rule 3 forbids additional steps and shuffles at any time. This
///   one is not a measurement problem — it was implemented and worked — it is a coaching one. The
///   window it can honestly police is the stretch with the hands off the deck, because rules 3 and 7
///   permit stepping freely at both ends of every rep while the hands are planted. That leaves it
///   firing on a narrow slice of the rep for a habit that costs an athlete far less than the two
///   placement rules below, and a fourth no-rep competing for one live cue makes the cues that matter
///   land less often.
enum BurpeeFault: Equatable {
    /// Rule 6 — the hands were planted more than 30 cm ahead of the front foot to start the burpee.
    /// `gap` is wrist to front toe, in torso lengths.
    case handsTooFarForward(gap: Double)
    /// Rule 5 — coming out of the burpee the feet came up past the hands. `overreach` is how far the
    /// front toe passed the fingertips, in torso lengths.
    case feetPastFingertips(overreach: Double)
    /// Rule 2a and 7 — the chest did not clearly touch the ground. `clearance` is how far the
    /// shoulders stayed above the feet at the lowest point, in torso lengths.
    case chestNotDown(clearance: Double)

    var title: String {
        switch self {
        case .handsTooFarForward: "Hands too far forward"
        case .feetPastFingertips: "Feet past the hands"
        case .chestNotDown: "Chest not down"
        }
    }

    /// Short imperative cue, sized for the live overlay. Every one leads with "No rep" because every
    /// one is a rule, which is not true at any other station.
    var liveMessage: String {
        switch self {
        case .handsTooFarForward: "No rep — hands back to your feet"
        case .feetPastFingertips: "No rep — feet behind your hands"
        case .chestNotDown: "No rep — chest to the floor"
        }
    }

    /// The coaching explanation — what happened, which rule it breaks, and what to do instead.
    var coachingDetail: String {
        switch self {
        case .handsTooFarForward(let gap):
            "You planted your hands about \(Self.approximateCentimetres(gap)) ahead of your front "
                + "toe, and rule 6 allows 30 cm. Step or jump in closer before you put the hands down. "
                + "Reaching forward to meet the floor is the most common way to give away reps you "
                + "have already done the work for, and it sets up the next rep badly too — hands out "
                + "in front are what force the feet to overshoot them coming back up."
        case .feetPastFingertips(let overreach):
            "Your front foot landed about \(Self.approximateCentimetres(overreach)) past your "
                + "fingertips coming out of the bottom, which rule 5 does not allow. Bring the feet up "
                + "to your hands, not past them — if you are overshooting every rep, your hands are "
                + "probably going down too far forward in the first place."
        case .chestNotDown(let clearance):
            "Your chest stayed about \(Self.approximateCentimetres(clearance)) off the floor at the "
                + "bottom, so the rep does not count. Rule 2a wants the nipple line making clear "
                + "contact — not a hover. Note that your thighs do not have to touch, and you are "
                + "allowed to come up off a knee, so the only thing to fix here is chest depth."
        }
    }

    /// Every case voids the rep, so every case is high severity. Priority is expressed by declaration
    /// order instead, not by grading the rules against each other.
    var severity: AlertSeverity { .high }

    /// Groups faults of the same kind for aggregate reporting, ignoring the measured value.
    var kind: Kind {
        switch self {
        case .handsTooFarForward: .handsTooFarForward
        case .feetPastFingertips: .feetPastFingertips
        case .chestNotDown: .chestNotDown
        }
    }

    /// Declaration order is coaching priority, because `faults.first` is what the athlete is told.
    ///
    /// **Rule 6 leads because it is the cause and rule 5 is the effect.** Hands planted out in front
    /// of the feet are what force the feet to overshoot the hands on the way back up, so an athlete
    /// who fixes their hand placement usually fixes both; one who is told about their feet first is
    /// being asked to correct a symptom. It is also the breach that persists longest unnoticed — the
    /// hands go down where the athlete is already reaching, every rep, for 80 m.
    ///
    /// Chest contact comes last of the three despite being the most fundamental. That is deliberate:
    /// a missed chest is a failure the athlete can already feel and will self-correct, while both
    /// placement rules are ones they cannot see themselves breaking.
    enum Kind: String, CaseIterable {
        case handsTooFarForward
        case feetPastFingertips
        case chestNotDown
    }

    /// Torso lengths rendered as a real-world distance, because the rulebook speaks in centimetres and
    /// so does the athlete.
    ///
    /// Carries the same assumed 50 cm torso as `BurpeeThresholds.maxHandsAheadOfFrontToe`, and is
    /// hedged with "about" for that reason — it is an estimate wearing a unit, and the wording should
    /// not imply a tape measure was involved.
    private static func approximateCentimetres(_ torsoLengths: Double) -> String {
        "\(Int((abs(torsoLengths) * 50).rounded())) cm"
    }
}
