import AVFoundation
import Foundation

protocol RepCuePlaying {
    func playShallowRepCue()
}

final class NoOpRepCuePlayer: RepCuePlaying {
    func playShallowRepCue() {}
}

final class SystemRepCuePlayer: NSObject, RepCuePlaying {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
    }

    func playShallowRepCue() {
        guard !synthesizer.isSpeaking else { return }

        let utterance = AVSpeechUtterance(string: "Squat lower")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 0.85
        synthesizer.speak(utterance)
    }
}