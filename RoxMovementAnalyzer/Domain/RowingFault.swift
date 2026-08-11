import Foundation

/// A technique fault detected on a single rowing stroke.
///
/// Like `WallBallFault` these are derived from body kinematics, not from the machine — the pose
/// model cannot see the handle, the chain or the monitor, so the wrists stand in for the handle and
/// every fault is phrased in terms of what the body did.
///
/// **Cases are split along measurement-reliability lines.** Where two errors in the same family
/// depend on different landmark groups they get separate cases, so losing one group suppresses only
/// the half that depended on it and never the half that is still measurable. On an erg the wrists
/// are the first thing to drop out — at the catch the hands sit directly over the shins — so
/// `sequenceArmsTooEarly` and `shortFinish` are independently suppressible from
/// `sequenceBackTooEarly` and `noLayback`, which need only the shoulders and hips.
///
/// Member names deliberately match `WallBallFault` so that a shared `MovementFault` protocol can be
/// introduced later, when the timeline and feedback surfaces are generalised, with no edits here.
///
/// Not derivable from body landmarks alone, and so deliberately absent: force, power and the shape
/// of the force curve; handle height at the catch and finish; whether the seat actually reached the
/// front stops (a short foot-stretcher setting looks identical to a short catch); and anything
/// involving damper, drag factor or split.
enum RowingFault: Equatable {
    /// The elbows bent before the legs finished driving, so the arms are trying to move a load the
    /// legs should already have moved. `offset` is negative seconds relative to the end of the leg
    /// drive.
    case sequenceArmsTooEarly(offset: Double)
    /// The torso swung open before the legs finished driving, spending the back's contribution
    /// early and leaving nothing to hang the arm draw on. `offset` is negative seconds.
    case sequenceBackTooEarly(offset: Double)
    /// The seat travelled away from the footplate while the handle stayed put — the legs pressed
    /// against nothing. `handleTravelRatio` is handle travel ÷ seat travel over the early drive,
    /// where a clean stroke sits at 1.0.
    case shootingTheSlide(handleTravelRatio: Double)
    /// The athlete never reached full compression at the catch, shortening the stroke at the front
    /// end. `kneeAngle` is the knee angle in degrees at the catch.
    case incompleteCatch(kneeAngle: Double)
    /// The torso never passed vertical at the finish, so the back's swing was left unused.
    /// `lean` is degrees from vertical, positive still leaning toward the flywheel.
    case noLayback(lean: Double)
    /// The handle was never drawn in to the body, shortening the stroke at the back end.
    /// `handleDistance` is how far ahead of the hips it finished, in torso lengths.
    case shortFinish(handleDistance: Double)
    /// The recovery was rushed back to the catch, so the athlete is pulling themselves up the slide
    /// instead of being carried. `ratio` is recovery time ÷ drive time, where 2.0 is the target.
    case rushingTheRecovery(ratio: Double)

    var title: String {
        switch self {
        case .sequenceArmsTooEarly: "Arms broke early"
        case .sequenceBackTooEarly: "Back opened early"
        case .shootingTheSlide: "Shooting the slide"
        case .incompleteCatch: "Short at the catch"
        case .noLayback: "No layback"
        case .shortFinish: "Handle never came in"
        case .rushingTheRecovery: "Rushing the recovery"
        }
    }

    /// Short imperative cue, sized for the live overlay.
    var liveMessage: String {
        switch self {
        case .sequenceArmsTooEarly: "Keep the arms long"
        case .sequenceBackTooEarly: "Hold the body over"
        case .shootingTheSlide: "Drive the handle with you"
        case .incompleteCatch: "Come up to the catch"
        case .noLayback: "Finish with a lean back"
        case .shortFinish: "Draw it to the ribs"
        case .rushingTheRecovery: "Slow the slide down"
        }
    }

    /// The coaching explanation — what happened and what to do instead.
    var coachingDetail: String {
        switch self {
        case .sequenceArmsTooEarly(let offset):
            "Your elbows bent \(Self.milliseconds(offset)) before your legs finished driving, so "
                + "the arms are fighting a load the legs should have moved. Keep the arms straight "
                + "and let them start pulling only once the legs are down."
        case .sequenceBackTooEarly(let offset):
            "Your torso opened \(Self.milliseconds(offset)) before your legs finished driving, so "
                + "the back's swing is spent before the arms have anything to hang it on. Hold the "
                + "body angle you set at the catch until the legs are down."
        case .shootingTheSlide(let ratio):
            "The handle only moved \(Self.percent(ratio)) as far as the seat over the first half of "
                + "the drive, so your hips ran out from under you and the legs pressed against "
                + "nothing. Push the footplate away and let the handle travel with you."
        case .incompleteCatch(let kneeAngle):
            "Your knees only closed to \(Int(kneeAngle.rounded()))° at the catch, so the stroke is "
                + "starting short. Come all the way up the slide until your shins are vertical "
                + "before you change direction."
        case .noLayback(let lean):
            "Your torso finished \(Self.degrees(lean)) of vertical, so the back's swing never made "
                + "it into the stroke. Finish leaning back to about eleven o'clock, with the legs "
                + "flat and the handle at your ribs."
        case .shortFinish(let handleDistance):
            "The handle stopped about \(String(format: "%.2f", handleDistance)) torso lengths in "
                + "front of your hips, so the last part of the stroke was left behind. Draw it all "
                + "the way in to your lower ribs before the hands go away."
        case .rushingTheRecovery(let ratio):
            "Your recovery was only \(String(format: "%.1f", ratio))× the length of your drive, so "
                + "you are pulling yourself back up the slide. Aim for about twice the drive time "
                + "— hands away, body over, then let the seat come."
        }
    }

    var severity: AlertSeverity {
        switch self {
        case .sequenceArmsTooEarly: .high
        case .sequenceBackTooEarly: .high
        case .shootingTheSlide: .high
        case .incompleteCatch: .medium
        case .noLayback: .medium
        case .shortFinish: .medium
        case .rushingTheRecovery: .low
        }
    }

    /// Groups faults of the same kind for aggregate reporting, ignoring the measured value.
    var kind: Kind {
        switch self {
        case .sequenceArmsTooEarly: .sequenceArmsTooEarly
        case .sequenceBackTooEarly: .sequenceBackTooEarly
        case .shootingTheSlide: .shootingTheSlide
        case .incompleteCatch: .incompleteCatch
        case .noLayback: .noLayback
        case .shortFinish: .shortFinish
        case .rushingTheRecovery: .rushingTheRecovery
        }
    }

    /// Declaration order is coaching priority, because `faults.first` is what the athlete is told.
    ///
    /// Unlike wall balls there is no rule-versus-inefficiency distinction to respect — the erg
    /// counts the metres either way — so this is purely which correction to make first: sequencing
    /// leaks the most power and is the root cause of the rest; range of motion is free metres left
    /// on the table; rhythm is real but often resolves itself once the sequence is fixed.
    enum Kind: String, CaseIterable {
        case sequenceArmsTooEarly
        case sequenceBackTooEarly
        case shootingTheSlide
        case incompleteCatch
        case noLayback
        case shortFinish
        case rushingTheRecovery
    }

    private static func milliseconds(_ seconds: Double) -> String {
        "\(Int(abs(seconds) * 1000)) ms"
    }

    private static func degrees(_ lean: Double) -> String {
        lean >= 0 ? "\(Int(lean.rounded()))° short" : "\(Int(abs(lean).rounded()))° past"
    }

    private static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
