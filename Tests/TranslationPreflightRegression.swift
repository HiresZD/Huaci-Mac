import Foundation
import NaturalLanguage

private struct PreflightFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct TranslationPreflightRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw PreflightFailure(description: message) }
    }

    static func main() throws {
        let english: TranslationPreflight.Hypotheses = { _ in [.english: 0.99] }
        let simplified: TranslationPreflight.Hypotheses = { _ in [.simplifiedChinese: 0.99] }
        let traditional: TranslationPreflight.Hypotheses = { _ in [.traditionalChinese: 0.99] }
        try check(TranslationPreflight.shouldSkipTranslation(text: "apple", target: .english,
                                                            hypotheses: english),
                  "A confidently identified same-language word must skip dictionary output")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "gift", target: .english,
                                                             hypotheses: { _ in [.english: 0.6, .german: 0.4] }),
                  "An ambiguous word must remain available to the translator")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "a", target: .english,
                                                             hypotheses: english),
                  "Very short Latin selections cannot be reliably identified")
        try check(TranslationPreflight.shouldSkipTranslation(text: "苹果", target: .simplifiedChinese,
                                                            hypotheses: simplified),
                  "A confident Chinese word with a variant cue may skip translation")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "蘋果", target: .simplifiedChinese,
                                                             hypotheses: simplified),
                  "Variant conversion must not be skipped even if recognition guesses wrong")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "苹果", target: .traditionalChinese,
                                                             hypotheses: traditional),
                  "The traditional target must retain simplified-to-traditional conversion")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "中文", target: .simplifiedChinese,
                                                             hypotheses: simplified),
                  "A short Han spelling shared across languages must remain conservative")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "今天学习 hello", target: .simplifiedChinese,
                                                             hypotheses: simplified),
                  "A dominant Chinese prediction must not hide an English fragment")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "Read this 中文", target: .english,
                                                             hypotheses: english),
                  "Mixed scripts must not be skipped based on the dominant language")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "Please visit this maison", target: .english,
                                                             hypotheses: { sample in
            sample == "maison" ? [.french: 0.99] : [.english: 0.99]
        }), "A confident foreign word in the same script must prevent skipping")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "Good morning. Bonjour tout le monde.",
                                                             target: .english, hypotheses: { sample in
            sample == "Bonjour tout le monde" ? [.french: 0.99] : [.english: 0.99]
        }), "Foreign sentences must not disappear behind a dominant-language score")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "12345 😀", target: .english,
                                                             hypotheses: english),
                  "Digits and emoji do not establish a source language")
        try check(!TranslationPreflight.shouldSkipTranslation(text: String(repeating: "a", count: 4_097),
                                                             target: .english, hypotheses: english),
                  "Local recognition work must remain bounded")
        try check(!TranslationPreflight.shouldSkipTranslation(text: "hello", target: .english,
                                                             hypotheses: { _ in [:] }),
                  "An unavailable local recognizer must fall back to translation")
        print("Translation preflight policy checks passed with injected evidence; no API or probabilistic model assertions.")
    }
}
