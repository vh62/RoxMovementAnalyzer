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
    /// Coaching cue for an inefficiency detected on the rep just finished.
    func faultCue(for fault: WallBallFault, station: HyroxStation) -> LiveFeedbackCue
    /// Shown when the hands leave frame during the throw, so release cannot be measured.
    func framingCue(for station: HyroxStation) -> LiveFeedbackCue
}

extension LiveFeedbackGenerating {
    func faultCue(for fault: WallBallFault, station: HyroxStation) -> LiveFeedbackCue {
        LiveFeedbackCue(
            station: station,
            message: fault.liveMessage,
            detail: fault.coachingDetail,
            status: fault.severity == .high ? .needsWork : .caution
        )
    }

    func framingCue(for station: HyroxStation) -> LiveFeedbackCue {
        LiveFeedbackCue(
            station: station,
            message: "Leave room overhead",
            detail: "Your hands go out of frame at the top of the throw, so release timing can't be "
                + "measured. Step back or tilt the phone up.",
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
                message: "Land both feet together",
                detail: "Live rule target: chest contact, aligned feet, close hands, then jump.",
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