import Foundation
import NaturalLanguage

/// A conservative, entirely local shortcut. `false` means "let the translator
/// decide", not necessarily that the selection is in a different language.
enum TranslationPreflight {
    typealias Hypotheses = (String) -> [NLLanguage: Double]

    static func shouldSkipTranslation(text: String, target: TranslationLanguage) -> Bool {
        shouldSkipTranslation(text: text, target: target) { sample in
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(sample)
            return recognizer.languageHypotheses(withMaximum: 5)
        }
    }

    /// The injectable recognizer keeps regression checks independent of changes
    /// to the statistical language models shipped with macOS.
    static func shouldSkipTranslation(text: String, target: TranslationLanguage,
                                      hypotheses: Hypotheses) -> Bool {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !sample.isEmpty, sample.utf16.count <= 4_096 else { return false }
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 2,
              letters.allSatisfy({ allowedScript($0.value, for: target) }) else { return false }

        let language = naturalLanguage(for: target)
        if target == .simplifiedChinese || target == .traditionalChinese {
            // Language recognition alone can confuse Chinese variants. If a
            // conversion changes the text, it must still go through translation.
            guard let simplified = sample.applyingTransform(StringTransform("Hant-Hans"), reverse: false),
                  let traditional = sample.applyingTransform(StringTransform("Hans-Hant"), reverse: false),
                  (target == .simplifiedChinese ? simplified : traditional) == sample else { return false }
            // A short shared Han spelling may also be a Japanese word. A clear
            // variant cue (e.g. 苹果 / 蘋果) permits a confident two-character word.
            guard letters.count >= 4 || simplified != traditional else { return false }
        } else if isLatin(target), letters.count < 4 {
            return false
        }

        let full = hypotheses(sample)
        guard confidentlyMatches(full, language: language, threshold: 0.92) else { return false }

        // A high dominant-language score is not proof that every sentence is in
        // that language. Check independent sentences before skipping the request.
        let sentences = Set(sample.components(separatedBy: CharacterSet(charactersIn: ".!?。！？;；\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.unicodeScalars.contains(where: CharacterSet.letters.contains) })
        let words = Set(sample.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters))
            .filter { $0.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count >= 3 })
        // Bound synchronous work. For long or heavily fragmented selections,
        // the model's same-language instruction remains the fallback.
        guard sentences.count + words.count <= 48 else { return false }
        for sentence in sentences where sentence != sample {
            guard confidentlyMatches(hypotheses(sentence), language: language, threshold: 0.80) else {
                return false
            }
        }
        for word in words where word != sample && !sentences.contains(word) {
            let evidence = hypotheses(word)
            if let strongest = evidence.max(by: { $0.value < $1.value }),
               strongest.key != language, strongest.value >= 0.95,
               (evidence[language] ?? 0) <= 0.15 {
                // Catches clearly foreign words even when both use Latin script.
                // Ambiguous words are not treated as positive evidence to skip.
                return false
            }
        }
        return true
    }

    private static func confidentlyMatches(_ evidence: [NLLanguage: Double],
                                          language: NLLanguage, threshold: Double) -> Bool {
        guard let confidence = evidence[language], confidence.isFinite,
              confidence >= threshold, confidence <= 1 else { return false }
        let rival = evidence.filter { $0.key != language }.map(\.value).max() ?? 0
        return confidence - rival >= 0.25
    }

    private static func naturalLanguage(for target: TranslationLanguage) -> NLLanguage {
        switch target {
        case .simplifiedChinese: return .simplifiedChinese
        case .traditionalChinese: return .traditionalChinese
        case .english: return .english
        case .japanese: return .japanese
        case .korean: return .korean
        case .french: return .french
        case .german: return .german
        case .spanish: return .spanish
        case .portuguese: return .portuguese
        case .russian: return .russian
        case .arabic: return .arabic
        }
    }

    private static func isLatin(_ target: TranslationLanguage) -> Bool {
        [TranslationLanguage.english, .french, .german, .spanish, .portuguese].contains(target)
    }

    private static func allowedScript(_ scalar: UInt32, for target: TranslationLanguage) -> Bool {
        let han = (0x3400...0x4DBF).contains(scalar) || (0x4E00...0x9FFF).contains(scalar)
            || (0xF900...0xFAFF).contains(scalar) || (0x20000...0x323AF).contains(scalar)
        switch target {
        case .simplifiedChinese, .traditionalChinese:
            return han
        case .japanese:
            return han || (0x3040...0x30FF).contains(scalar) || (0x31F0...0x31FF).contains(scalar)
                || (0x1B000...0x1B16F).contains(scalar) || (0xFF66...0xFF9D).contains(scalar)
        case .korean:
            return han || (0x1100...0x11FF).contains(scalar) || (0x3130...0x318F).contains(scalar)
                || (0xA960...0xA97F).contains(scalar) || (0xAC00...0xD7AF).contains(scalar)
                || (0xD7B0...0xD7FF).contains(scalar)
        case .russian:
            return (0x0400...0x052F).contains(scalar) || (0x2DE0...0x2DFF).contains(scalar)
                || (0xA640...0xA69F).contains(scalar) || (0x1C80...0x1C8F).contains(scalar)
        case .arabic:
            return (0x0600...0x06FF).contains(scalar) || (0x0750...0x077F).contains(scalar)
                || (0x08A0...0x08FF).contains(scalar) || (0xFB50...0xFDFF).contains(scalar)
                || (0xFE70...0xFEFF).contains(scalar) || (0x1EE00...0x1EEFF).contains(scalar)
        default:
            return (0x0041...0x005A).contains(scalar) || (0x0061...0x007A).contains(scalar)
                || (0x00C0...0x024F).contains(scalar) || (0x1E00...0x1EFF).contains(scalar)
        }
    }
}
