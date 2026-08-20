import Foundation

/// A technique fault detected on a single SkiErg pull.
///
/// Like `RowingFault` and `WallBallFault` these come from body kinematics, not from the machine: the
/// pose model cannot see the handles, the cords or the monitor, so the wrists stand in for the handles
/// and every fault is phrased in terms of what the body did.
///
/// **Two families, and only two.** The hinge is what makes a pull powerful, and the force curve is
/// where that power lands. Everything else a rowing-shaped fault set would suggest was either wrong
/// here or peripheral — see the note on the arms below.
///
/// **Cases are split along measurement-reliability lines**, the same rule `RowingFault` follows, and
/// the split falls cleanly between the two families: the hinge checks need shoulders, hips and knees;
/// the force-curve checks need the wrists. On a SkiErg the wrists are the first landmark to go — the
/// catch puts the hands above the head, exactly where a tight frame runs out of picture — so losing
/// them costs the force curve and nothing else, including nothing of the segmentation.
///
/// **There is deliberately no "arms broke early".** That is a RowErg cue and it is wrong here: in
/// double poling the elbows are *supposed* to flex through the compression, and the triceps extension
/// is the finish of the stroke, so a check on arm timing would fire on correct technique. The real
/// concern behind it — body and arms working as two separate efforts rather than one — is
/// `disconnectedDrive`, which reads it off the force curve without asserting anything about elbows.
///
/// Not derivable from body landmarks alone, and so deliberately absent: absolute force in newtons,
/// grip height on the handle, how much of the pull the cords actually took, and anything involving
/// damper, drag factor or split.
enum SkiFault: Equatable {
    /// The knees did the work the hip hinge should have done — the athlete rode up and down on the
    /// machine instead of folding onto the handles. `hingeToKneeRatio` is degrees of forward torso
    /// swing ÷ degrees of knee flexion over the drive, where a hinge-led pull sits above 1.
    case squattingNotHinging(hingeToKneeRatio: Double)
    /// The torso never hinged, so the pull came from the arms alone. `lean` is degrees of forward torso
    /// lean at the finish.
    case noHipHinge(lean: Double)
    /// Peak power arrived late in the drive: the athlete drifted through the top of the range without
    /// loading the cords and then finished with the arms, instead of committing the body early.
    /// `peakAtDriveFraction` is where the peak sat, 0 at the catch and 1 at the finish.
    ///
    /// This is deliberately **one** check rather than two. "Did they load at the top" and "did the
    /// power land late" read as different questions, but on a single-peaked speed profile they are the
    /// same number seen from opposite ends — measured over the fixture, mean opening-quarter speed
    /// tracked peak position monotonically at every window width tried, carrying no information of its
    /// own. Shipping both would report one defect twice. The opening-quarter figure survives as a
    /// reported metric, where it tells the athlete *how* the pull was shaped without claiming to be a
    /// second finding.
    case backLoadedDrive(peakAtDriveFraction: Double)
    /// The drive came in two separate efforts with a lull between them — body, pause, then arms —
    /// instead of one blended push. `dip` is the trough between the two peaks ÷ the smaller of them.
    case disconnectedDrive(dip: Double)

    var title: String {
        switch self {
        case .squattingNotHinging: "Squatting, not hinging"
        case .noHipHinge: "No hip hinge"
        case .backLoadedDrive: "Power comes too late"
        case .disconnectedDrive: "Body and arms split"
        }
    }

    /// Short imperative cue, sized for the live overlay.
    var liveMessage: String {
        switch self {
        case .squattingNotHinging: "Hinge, don't squat"
        case .noHipHinge: "Fold onto the handles"
        case .backLoadedDrive: "Hit it early"
        case .disconnectedDrive: "One smooth drive"
        }
    }

    /// The coaching explanation — what happened and what to do instead.
    var coachingDetail: String {
        switch self {
        case .squattingNotHinging(let ratio):
            "Your torso only swung \(Self.percent(ratio)) as far as your knees bent, so you are riding "
                + "up and down on the machine rather than driving the handles. Push the hips back and "
                + "fold at the waist, with the knees only softening."
        case .noHipHinge(let lean):
            "Your torso only reached \(Int(lean.rounded()))° of forward lean at the finish, so the pull "
                + "came from the arms alone. Hinge at the hips and let your bodyweight fall onto the "
                + "handles — that is where the power on a ski comes from."
        case .backLoadedDrive(let fraction):
            "Your power peaked \(Self.percent(fraction)) of the way down the pull, so you drifted "
                + "through the top of the range and finished with the arms. Set your weight on the "
                + "handles at full reach and commit the hinge early, so the peak arrives in the first "
                + "third."
        case .disconnectedDrive(let dip):
            "Your drive came in two efforts with a lull between them — speed fell to \(Self.percent(dip)) "
                + "of the peak in the middle — so the body and the arms are taking turns instead of "
                + "working together. Blend the hinge into the arm finish as one continuous push."
        }
    }

    var severity: AlertSeverity {
        switch self {
        case .squattingNotHinging: .high
        case .noHipHinge: .high
        case .backLoadedDrive: .medium
        case .disconnectedDrive: .medium
        }
    }

    /// Groups faults of the same kind for aggregate reporting, ignoring the measured value.
    var kind: Kind {
        switch self {
        case .squattingNotHinging: .squattingNotHinging
        case .noHipHinge: .noHipHinge
        case .backLoadedDrive: .backLoadedDrive
        case .disconnectedDrive: .disconnectedDrive
        }
    }

    /// Declaration order is coaching priority, because `faults.first` is what the athlete is told.
    ///
    /// As with rowing there is no rule-versus-inefficiency split to respect — the SkiErg logs the
    /// metres whatever the pull looked like — so this is purely which correction to make first. The
    /// hinge comes before the force curve because a pull with no hinge has no power to place; once the
    /// body is in it, where the peak lands and whether it arrives in one piece are the refinements.
    ///
    /// Four checks, not six. Two rowing transplants (`sequenceArmsTooEarly`, `shortFinish`) were wrong
    /// or peripheral here, and a third (`lateEngagement`) turned out to be `backLoadedDrive` measured
    /// from the other end.
    enum Kind: String, CaseIterable {
        case squattingNotHinging
        case noHipHinge
        case backLoadedDrive
        case disconnectedDrive
    }

    private static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }
}
