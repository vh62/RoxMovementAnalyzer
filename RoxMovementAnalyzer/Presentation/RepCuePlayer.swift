import AVFoundation
import Foundation

protocol RepCuePlaying {
    /// Speaks a station's no-rep cue. The phrase is passed in rather than baked in because more than
    /// one station has a no-rep now — see `HyroxStation.noRepPhrase`.
    func playNoRepCue(_ phrase: String)
}

final class NoOpRepCuePlayer: RepCuePlaying {
    func playNoRepCue(_ phrase: String) {}
}

final class SystemRepCuePlayer: NSObject, RepCuePlaying {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
    }

    func playNoRepCue(_ phrase: String) {
        guard !synthesizer.isSpeaking else { return }

        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 0.85
        synthesizer.speak(utterance)
    }
}