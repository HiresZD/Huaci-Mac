import Foundation

private struct SpeechTestFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class MockSpeechOutput: EnglishSpeechOutput {
    var events: [String] = []
    var fail = false
    func stop() { events.append("stop") }
    func speak(word: String, accent: EnglishAccent) throws {
        events.append("speak:\(accent.rawValue):\(word)")
        if fail { throw EnglishSpeechError(message: "No test voice") }
    }
}

@main
struct EnglishSpeechRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw SpeechTestFailure(description: message) }
    }

    @MainActor
    static func main() throws {
        // No audio, network, installed-voice enumeration, or preferences access.
        let voices = [
            EnglishVoiceDescriptor(identifier: "us-default", language: "en-US", quality: 1),
            EnglishVoiceDescriptor(identifier: "us-enhanced", language: "en-US", quality: 2),
            EnglishVoiceDescriptor(identifier: "gb", language: "en_GB", quality: 2),
            EnglishVoiceDescriptor(identifier: "fr", language: "fr-FR", quality: 3),
            EnglishVoiceDescriptor(identifier: "personal", language: "en-US", quality: 3, isPersonal: true),
            EnglishVoiceDescriptor(identifier: "novelty", language: "en-US", quality: 3, isNovelty: true)
        ]
        try expect(EnglishVoiceSelection.identifier(for: .american, voices: voices,
                    preferredIdentifier: "us-default") == "us-enhanced",
                   "Prefer higher-quality installed English voices, excluding personal and novelty voices")
        try expect(EnglishVoiceSelection.identifier(for: .british, voices: voices,
                    preferredIdentifier: "us-enhanced") == "gb",
                   "British preference must remain British even when another default voice exists")
        try expect(EnglishVoiceSelection.identifier(for: .british, voices: [voices[0]],
                    preferredIdentifier: "us-default") == nil,
                   "A missing accent must report unavailable, never silently speak another accent")
        try expect(EnglishVoiceSelection.identifier(for: .american, voices: [],
                    preferredIdentifier: nil) == nil, "No installed voice must be handled")

        let output = MockSpeechOutput()
        let controller = EnglishSpeechController(output: output)
        try controller.speak(word: "apple", accent: .american)
        try controller.speak(word: "apple", accent: .american)
        try controller.speak(word: "run", accent: .british)
        controller.stop()
        try expect(output.events == ["stop", "speak:en-US:apple", "stop", "speak:en-US:apple",
                                     "stop", "speak:en-GB:run", "stop"],
                   "Repeated clicks restart; new words use the selected accent; close stops playback")
        do {
            try controller.speak(word: "apple juice", accent: .american)
            throw SpeechTestFailure(description: "A phrase must not be sent to single-word pronunciation")
        } catch is EnglishSpeechError { }
        try expect(output.events.last == "stop", "Rejected text still cancels prior speech")
        output.fail = true
        do {
            try controller.speak(word: "apple", accent: .american)
            throw SpeechTestFailure(description: "Missing voice must propagate as a visible speech error")
        } catch is EnglishSpeechError { }
        output.fail = false
        try controller.speak(word: "don't", accent: .british)
        try expect(output.events.last == "speak:en-GB:don't", "A failed voice lookup must not poison later playback")

        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"model":"saved-model","translationTarget":"ko"}"#.utf8))
        try expect(old.englishAccent == .american && old.translationTarget == "ko" && old.model == "saved-model",
                   "An old settings file must keep API/translation settings and receive the default accent")
        let unknown = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"englishAccent":"bad-value"}"#.utf8))
        try expect(unknown.englishAccent == .american, "Unknown saved accents must safely use the default")
        var changed = old
        changed.englishAccent = .british
        let encoded = try JSONEncoder().encode(changed)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)
        try expect(decoded.englishAccent == .british && decoded.translationTarget == "ko",
                   "Changing and persisting accent must preserve the translation target")
        print("English pronunciation policy checks passed; no audio played.")
    }
}
