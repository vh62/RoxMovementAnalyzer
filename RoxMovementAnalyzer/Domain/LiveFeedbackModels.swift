import Foundation

struct LiveFeedbackCue: Identifiable, Equatable {
    let id = UUID()
    let station: HyroxStation
    let message: String
    let detail: String
    let status: StationStatus
}

protocol LiveFeedbackGenerating {
    func readyCue(for station: HyroxStation) -> LiveFeedbackCue
    func recordingCue(for station: HyroxStation) -> LiveFeedbackCue
    func completedCue(for station: HyroxStation) -> LiveFeedbackCue
    /// Coaching cue for a fault detected on the movement just finished.
    func faultCue(for fault: FaultCallout, station: HyroxStation) -> LiveFeedbackCue
    /// Shown when the hands leave frame, so the throw or the handle draw cannot be measured.
    func framingCue(for station: HyroxStation) -> LiveFeedbackCue
}

extension LiveFeedbackGenerating {
    func faultCue(for fault: FaultCallout, station: HyroxStation) -> LiveFeedbackCue {
        LiveFeedbackCue(
            station: station,
            message: fault.liveMessage,
            detail: fault.coachingDetail,
            status: fault.severity == .high ? .needsWork : .caution
        )
    }

    /// Worded per station, because what losing the hands costs differs — release timing on a wall
    /// ball, the handle draw on either erg, both placement rules on a burpee — and a cue that named
    /// the wrong movement would read as the app not knowing what it was watching.
    ///
    /// Burpees are also the one station where the hands are lost at the *bottom* rather than the top,
    /// so the instruction is the opposite one.
    func framingCue(for station: HyroxStation) -> LiveFeedbackCue {
        let detail: String
        switch station {
        case .burpeeBroadJumps:
            return LiveFeedbackCue(
                station: station,
                message: "Show your hands on the floor",
                detail: "Your hands drop out of frame at the bottom, so the hand and foot placement "
                    + "rules can't be judged. Lower the phone or step back.",
                status: .caution
            )
        case .skiErg:
            detail = "Your hands go out of frame at the top of the pull, so the reach and the handle "
                + "draw can't be measured. Step back or tilt the phone up."
        case .rowing:
            detail = "Your hands leave frame during the stroke, so the handle draw can't be measured. "
                + "Step back or turn the phone to landscape."
        default:
            detail = "Your hands go out of frame at the top of the throw, so release timing can't be "
                + "measured. Step back or tilt the phone up."
        }

        return LiveFeedbackCue(
            station: station,
            message: "Leave room overhead",
            detail: detail,
            status: .caution
        )
    }
}

struct StationRuleLiveFeedbackGenerator: LiveFeedbackGenerating {
    /// Deliberately says nothing about framing: the on-screen prompt owns that, and it knows
    /// whether the body is actually tracked rather than repeating a standing instruction.
    func readyCue(for station: HyroxStation) -> LiveFeedbackCue {
        LiveFeedbackCue(
            station: station,
            message: "Ready when you are",
            detail: "Tap record to start the set.",
            status: .raceReady
        )
    }

    func recordingCue(for station: HyroxStation) -> LiveFeedbackCue {
        switch station {
        case .skiErg:
            LiveFeedbackCue(
                station: station,
                message: "Hinge, then drive down",
                detail: "Live rule target: load the hips before the handle drop and keep peak force in the drive phase.",
                status: .raceReady
            )
        case .wallBalls:
            LiveFeedbackCue(
                station: station,
                message: "Hit depth before release",
                detail: "Live rule target: hips below knees, then drive the ball upward.",
                status: .raceReady
            )
        case .sledPush:
            LiveFeedbackCue(
                station: station,
                message: "Lean into the drive",
                detail: "Live rule target: keep back angle under 45 degrees through the push.",
                status: .strong
            )
        case .sledPull:
            LiveFeedbackCue(
                station: station,
                message: "Stay low with long arms",
                detail: "Live rule target: maintain rope tension before bending the elbows.",
                status: .caution
            )
        case .burpeeBroadJumps:
            LiveFeedbackCue(
                station: station,
                message: "Hands and feet close",
                detail: "Live rule target: hands within 30 cm of your toes, feet no further "
                    + "forward than your fingertips, and chest to the floor.",
                status: .caution
            )
        case .rowing:
            LiveFeedbackCue(
                station: station,
                message: "Legs, back, then arms",
                detail: "Live rule target: delay torso opening and arm pull until leg drive finishes.",
                status: .raceReady
            )
        case .running:
            LiveFeedbackCue(
                station: station,
                message: "Keep stride balanced",
                detail: "Live rule target: maintain even left-right stride length and target cadence.",
                status: .raceReady
            )
        case .lunges:
            LiveFeedbackCue(
                station: station,
                message: "Touch knee, load hips",
                detail: "Live rule target: confirm rear knee contact and avoid collapsing into the front quad.",
                status: .caution
            )
        }
    }

    func completedCue(for station: HyroxStation) -> LiveFeedbackCue {
        LiveFeedbackCue(
            station: station,
            message: "Session captured",
            detail: "Review the scorecard for rule checks, red flags, and next training focus.",
            status: .strong
        )
    }
}