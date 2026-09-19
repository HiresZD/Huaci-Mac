import Foundation
import AVFAudio

struct EnglishSpeechError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Plain descriptors let the selection policy be checked without playing audio
/// or depending on the voices installed on the machine running the tests.
struct EnglishVoiceDescriptor {
    let identifier: String
    let language: String
    let quality: Int
    var isPersonal = false
    var isNovelty = false
}

enum EnglishVoiceSelection {
    static func identifier(for accent: EnglishAccent, voices: [EnglishVoiceDescriptor],
                           preferredIdentifier: String?) -> String? {
        let locale = accent.rawValue.lowercased()
        return voices.filter {
            $0.language.replacingOccurrences(of: "_", with: "-").lowercased() == locale &&
                !$0.isPersonal && !$0.isNovelty
        }.sorted {
            if $0.quality != $1.quality { return $0.quality > $1.quality }
            let leftPreferred = $0.identifier == preferredIdentifier
            let rightPreferred = $1.identifier == preferredIdentifier
            if leftPreferred != rightPreferred { return leftPreferred }
            return $0.identifier < $1.identifier
        }.first?.identifier
    }
}

@MainActor
protocol EnglishSpeechOutput: AnyObject {
    func speak(word: String, accent: EnglishAccent) throws
    func stop()
}

@MainActor
final class EnglishSpeechController {
    private let output: EnglishSpeechOutput

    init() { output = SystemEnglishSpeechOutput() }
    init(output: EnglishSpeechOutput) { self.output = output }

    func speak(word: String, accent: EnglishAccent) throws {
        // Stop first: fast repeat clicks must restart, never accumulate a queue.
        output.stop()
        guard TranslationRequest.sourceWord(text: word) == word else {
            throw EnglishSpeechError(message: "当前内容不是可朗读的单个英文词。")
        }
        try output.speak(word: word, accent: accent)
    }

    func stop() { output.stop() }
}

@MainActor
private final class SystemEnglishSpeechOutput: EnglishSpeechOutput {
    // Keep the synthesizer alive until speech ends, as required by AVFAudio.
    private let synthesizer = AVSpeechSynthesizer()

    func speak(word: String, accent: EnglishAccent) throws {
        let voices = AVSpeechSynthesisVoice.speechVoices()
        let descriptors = voices.map { voice -> EnglishVoiceDescriptor in
            var descriptor = EnglishVoiceDescriptor(identifier: voice.identifier,
                language: voice.language, quality: voice.quality.rawValue)
            #if compiler(>=5.9)
            if #available(macOS 14.0, *) {
                descriptor.isPersonal = voice.voiceTraits.contains(.isPersonalVoice)
                descriptor.isNovelty = voice.voiceTraits.contains(.isNoveltyVoice)
            }
            #endif
            return descriptor
        }
        let preferred = AVSpeechSynthesisVoice(language: accent.rawValue)?.identifier
        guard let identifier = EnglishVoiceSelection.identifier(for: accent, voices: descriptors,
                                                                 preferredIdentifier: preferred),
              let voice = voices.first(where: { $0.identifier == identifier }) else {
            throw EnglishSpeechError(message:
                "未找到\(accent.title)系统语音。请在系统设置 → 辅助功能的朗读设置中下载对应语音，或更换发音口音。")
        }
        // Synthesize the selected source word, not its IPA or translated meaning.
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
}
