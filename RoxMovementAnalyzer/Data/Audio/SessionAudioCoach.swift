import AVFoundation
import Foundation
import os

/// Speaks the two things an athlete needs to hear mid-set: the rep count, and a no-rep when the
/// squat was too shallow.
///
/// Only those two. Release timing and catch distance stay on screen and on the scorecard —
/// nobody can act on a paragraph of coaching between reps, and every extra utterance competes
/// with the count for airtime.
///
/// Audio is deliberately limited to headphones. A gym is too loud for the phone speaker to be
/// useful and too public for it to be comfortable, so with nothing connected this stays silent.
@MainActor
final class SessionAudioCoach {
    private static let log = Logger(subsystem: "rox.audio", category: "SessionAudioCoach")

    /// Minimum gap between utterances. Reps land roughly every two seconds and a spoken cue takes
    /// about one, so without this the count would run continuously.
    private let minimumGap: TimeInterval = 0.9

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenAt: Date?
    private var isSessionActive = false

    /// Whether audio would be heard right now — used by the UI to explain the silence.
    var hasAudioOutput: Bool { Self.isHeadphoneRoute() }

    // MARK: - Session lifecycle

    /// Claims the audio session for the duration of a set.
    ///
    /// `.duckOthers` dips the athlete's music for a cue rather than stopping it, and `.playback`
    /// keeps cues audible with the ringer switch silenced — which is what someone who asked for
    /// spoken coaching expects.
    func startSession() {
        guard !isSessionActive else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            isSessionActive = true
            prewarm()
        } catch {
            Self.log.error("could not start audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Releases the session so the athlete's music comes back up.
    func endSession() {
        guard isSessionActive else { return }
        isSessionActive = false
        lastSpokenAt = nil

        synthesizer.stopSpeaking(at: .immediate)

        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: [.notifyOthersOnDeactivation]
            )
        } catch {
            Self.log.error("could not end audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Cues

    /// Counts a rep that broke parallel.
    func announce(rep: Int) {
        speak("\(rep)")
    }

    /// Calls a rep that did not break parallel.
    func announceNoRep() {
        speak("No rep")
    }

    // MARK: - Speaking

    private func speak(_ phrase: String) {
        guard isSessionActive, Self.isHeadphoneRoute() else { return }

        // Drop rather than queue. A backlog would narrate reps the athlete has already finished,
        // and a stale count is worse than a missing one.
        guard !synthesizer.isSpeaking else { return }
        if let lastSpokenAt, Date().timeIntervalSince(lastSpokenAt) < minimumGap { return }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.1
        utterance.postUtteranceDelay = 0
        synthesizer.speak(utterance)
        lastSpokenAt = Date()
    }

    /// The first utterance is otherwise noticeably slower, which would land the opening count
    /// late enough to look wrong.
    private func prewarm() {
        let warmup = AVSpeechUtterance(string: " ")
        warmup.volume = 0
        synthesizer.speak(warmup)
    }

    /// Checked per cue rather than cached: AirPods connect and drop out mid-set.
    private static func isHeadphoneRoute() -> Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP, .airPlay:
                true
            default:
                false
            }
        }
    }
}
