import Foundation

/// A movement inefficiency detected on a single wall-ball rep.
///
/// These are derived from body kinematics, not from tracking the ball — the pose model has no
/// concept of the ball. While it is held the hands are on it, so the wrists stand in for it, and
/// the faults are phrased in terms of what the body did (which is what the athlete can change).
enum WallBallFault: Equatable {
    /// The hips never broke below the knee, so the rep does not count. `shortfall` is how far
    /// above parallel they stopped, as a percentage of frame height.
    ///
    /// Unlike the others this is a rule rather than an inefficiency, which is why it takes
    /// precedence and why it is the one fault spoken aloud during a set.
    case shallowDepth(shortfall: Double)
    /// The arms started driving before the legs finished extending, so the throw is powered by
    /// the arms instead of the leg drive. `offset` is negative seconds.
    case earlyRelease(offset: Double)
    /// The legs finished extending and there was a pause before the arms drove, losing the
    /// momentum of the drive. `offset` is positive seconds.
    case lateRelease(offset: Double)
    /// The ball was received too far in front of the body, pulling the athlete forward.
    /// `reach` is in torso lengths.
    case catchTooFarForward(reach: Double)

    var title: String {
        switch self {
        case .shallowDepth: "Shallow squat"
        case .earlyRelease: "Arms fired early"
        case .lateRelease: "Dead spot at the top"
        case .catchTooFarForward: "Catching too far out"
        }
    }

    /// Short imperative cue, sized for the live overlay.
    var liveMessage: String {
        switch self {
        case .shallowDepth: "No rep — break parallel"
        case .earlyRelease: "Finish your legs first"
        case .lateRelease: "Throw as the legs finish"
        case .catchTooFarForward: "Catch it closer in"
        }
    }

    /// The coaching explanation — what happened and what to do instead.
    var coachingDetail: String {
        switch self {
        case .shallowDepth(let shortfall):
            "Your hips stopped about \(String(format: "%.1f", shortfall))% of frame height above "
                + "the knee, so the rep does not count. Sink until the hip crease drops below the "
                + "top of the knee before you drive up."
        case .earlyRelease(let offset):
            "Your arms started \(Self.milliseconds(offset)) before your legs finished extending, "
                + "so the ball is going up on arm strength. Drive all the way through your legs, "
                + "then let the arms follow."
        case .lateRelease(let offset):
            "You paused \(Self.milliseconds(offset)) after full leg extension before throwing, "
                + "which wastes the drive and costs time every rep. Let the throw ride the "
                + "momentum of the stand-up."
        case .catchTooFarForward(let reach):
            "You received the ball about \(String(format: "%.1f", reach)) torso-widths in front of "
                + "your shoulders, which pulls you forward and forces your quads to fight the "
                + "descent. Meet it closer to your chest and absorb straight down."
        }
    }

    var severity: AlertSeverity {
        switch self {
        case .shallowDepth: .high
        case .earlyRelease: .high
        case .lateRelease: .medium
        case .catchTooFarForward: .medium
        }
    }

    /// Groups faults of the same kind for aggregate reporting, ignoring the measured value.
    var kind: Kind {
        switch self {
        case .shallowDepth: .shallowDepth
        case .earlyRelease: .earlyRelease
        case .lateRelease: .lateRelease
        case .catchTooFarForward: .catchTooFarForward
        }
    }

    enum Kind: String, CaseIterable {
        case shallowDepth
        case earlyRelease
        case lateRelease
        case catchTooFarForward
    }

    private static func milliseconds(_ seconds: Double) -> String {
        "\(Int(abs(seconds) * 1000)) ms"
    }
}
