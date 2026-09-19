import Foundation

private struct DictionaryFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct DictionaryRegression {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try condition()) { throw DictionaryFailure(description: message) }
    }

    static func reject(_ response: String, _ message: String) throws {
        do { _ = try DictionaryEntry.parse(response) }
        catch is DictionaryEntryError { return }
        throw DictionaryFailure(description: message)
    }

    static func rejectResponse(_ response: String, _ message: String) throws {
        do { _ = try DictionaryResponse.parse(response) }
        catch is DictionaryEntryError { return }
        throw DictionaryFailure(description: message)
    }

    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    static func main() throws {
        for (selection, expected) in [
            ("apple", "apple"), ("  ‘apple!’ \n", "apple"), ("(Apple).", "Apple"),
            ("don't", "don't"), ("don’t", "don’t"), ("well-known", "well-known"),
            ("mother-in-law", "mother-in-law"), ("I", "I"), ("a", "a"), ("run", "run"), ("dog", "dog")
        ] {
            try check(TranslationRequest.sourceWord(text: selection) == expected,
                      "A source word, contraction, or hyphenated compound must keep dictionary routing: \(selection)")
        }
        for selection in ["ice cream", "New York", "This is a sentence.", "one\ntwo", "",
                          "123", "42nd", "https://example.com", "example.com", "foo_bar", "getValue",
                          "HTTPServer", "word1", "foo()bar", "foo()", "foo[]", "<div>", "--help", "hello/world", "a+b",
                          "中文", "こんにちは", "مرحبا", "안녕", "word😀", "one—two"] {
            try check(TranslationRequest.sourceWord(text: selection) == nil,
                      "Phrases, URLs, obvious identifiers, and other scripts must not enter the Latin-word route: \(selection)")
        }

        // Switching targets never uses an old translated word as the next source.
        // Only system + current source are sent, even after Arabic/Korean targets.
        for target in ["简体中文", "阿拉伯语", "韩语", "简体中文"] {
            guard let word = TranslationRequest.sourceWord(text: "“apple”") else {
                throw DictionaryFailure(description: "Target changes must not remove a source word")
            }
            let messages = TranslationRequest.dictionaryMessages(word: word, targetLanguage: target)
            let repair = TranslationRequest.dictionaryMessages(word: word, targetLanguage: target, repair: true)
            try check(messages.count == 2 && messages[0].role == "system" && messages[1].role == "user",
                      "A dictionary lookup must remain independent of chat or prior translation history")
            try check(messages[1].content == "apple" && repair[1] == messages[1],
                      "Every target and a format repair must receive the identical original word")
        }

        let arabic: [String: Any] = [
            "sourceLanguage": "en",
            "pronunciation": "/ˈæpəl/",
            "senses": [["partOfSpeech": "اسم", "meaning": "تفاحة؛ ثمرة مستديرة تؤكل طازجة."]],
            "collocations": [["text": "apple juice", "translation": "عصير التفاح"]],
            "examples": [["text": "She ate an apple.", "translation": "أكلت تفاحة."]]
        ]
        let encoded = try json(arabic)
        let entry = try DictionaryEntry.parse(encoded)
        try check(try DictionaryResponse.parse(encoded) == .entry(entry),
                  "A complete entry must remain an entry when using the response discriminator")
        try check(entry.sourceLanguage == "en" && entry.pronunciation == "/ˈæpəl/" && entry.senses[0].partOfSpeech == "اسم",
                  "English source language, IPA, and Arabic part of speech must survive decoding independently")
        try check(entry.collocations[0].translation == "عصير التفاح" && entry.examples[0].text == "She ate an apple.",
                  "Original phrases and target-language translations must remain separate")
        try check(try DictionaryEntry.parse("```json\n\(encoded)\n```") == entry,
                  "Exactly one complete JSON fence is a supported compatibility format")

        let korean: [String: Any] = [
            "sourceLanguage": "en",
            "pronunciation": "/ˈæpəl/",
            "senses": [["partOfSpeech": "명사", "meaning": "사과; 둥글고 달콤한 과일."]],
            "collocations": [["text": "apple tree", "translation": "사과나무"]],
            "examples": [["text": "I picked an apple.", "translation": "나는 사과 하나를 땄다."]]
        ]
        let koreanEntry = try DictionaryEntry.parse(json(korean))
        try check(koreanEntry.senses[0].meaning == "사과; 둥글고 달콤한 과일." &&
                  koreanEntry.examples[0].translation == "나는 사과 하나를 땄다.",
                  "Korean dictionary sections must survive instead of becoming a single translated word")

        var unknownPronunciation = arabic
        unknownPronunciation["pronunciation"] = NSNull()
        try check(try DictionaryEntry.parse(json(unknownPronunciation)).pronunciation == nil,
                  "Explicitly unverified IPA must remain nil for a consistent UI placeholder")

        // The source router accepts Latin letters, which are not evidence of
        // English. The identified source language must control speech eligibility.
        try check(TranslationRequest.sourceWord(text: "bonjour") == "bonjour",
                  "A non-English Latin word can enter the dictionary route")
        let french: [String: Any] = [
            "sourceLanguage": "fr",
            "pronunciation": "/bɔ̃.ʒuʁ/",
            "senses": [["partOfSpeech": "感叹词", "meaning": "你好；白天见面时使用的问候语。"]],
            "collocations": [["text": "dire bonjour", "translation": "打招呼"]],
            "examples": [["text": "Bonjour, Marie !", "translation": "你好，玛丽！"]]
        ]
        try check(try DictionaryEntry.parse(json(french)).sourceLanguage == "fr",
                  "Non-English Latin source words must not be relabeled English")
        for language in ["und", "fil"] {
            var identified = arabic
            identified["sourceLanguage"] = language
            try check(try DictionaryEntry.parse(json(identified)).sourceLanguage == language,
                      "Unknown and three-letter source codes must remain explicit: \(language)")
        }
        let invalidLanguages: [Any] = ["", "English", "EN", "en-US", "en_US", " en", "en ", "en\n", "e", "abcd", "中文", 1, true, NSNull()]
        for invalidLanguage in invalidLanguages {
            var malformedLanguage = arabic
            malformedLanguage["sourceLanguage"] = invalidLanguage
            try reject(json(malformedLanguage), "Source language must be a lowercase two- or three-letter code: \(invalidLanguage)")
        }

        try reject("تفاحة", "A lone Arabic translation must never count as a complete dictionary")
        try reject("사과", "A lone Korean translation must never count as a complete dictionary")
        try reject("{\"translation\":\"苹果\"}", "A JSON translation alone must not count as a dictionary")
        for key in ["sourceLanguage", "pronunciation", "senses", "collocations", "examples"] {
            var missing = arabic
            missing.removeValue(forKey: key)
            try reject(json(missing), "Missing \(key) must be rejected")
        }
        for key in ["senses", "collocations", "examples"] {
            var empty = arabic
            empty[key] = [] as [Any]
            try reject(json(empty), "Empty \(key) must not count as a valid section")
        }
        var malformed = arabic
        malformed["pronunciation"] = " "
        try reject(json(malformed), "Blank pronunciation must be explicit null instead")
        malformed = arabic
        malformed["senses"] = [["partOfSpeech": "اسم", "meaning": "\n "]]
        try reject(json(malformed), "A blank definition must be rejected")
        malformed = arabic
        malformed["examples"] = [["text": "She ate an apple."]]
        try reject(json(malformed), "A source-language example without a translation is incomplete")
        try reject("Here is the dictionary:\n\(encoded)", "Prose before JSON must not be silently extracted")
        try reject("```json\n\(encoded)\n```\n```json\n{}\n```", "Multiple JSON fences must be rejected")
        try reject(String(repeating: "x", count: DictionaryEntry.maximumResponseBytes + 1),
                   "Oversized dictionary output must be bounded")

        try check(try DictionaryResponse.parse("{\"sameLanguage\":true}") == .sameLanguage,
                  "A same-language result must bypass dictionary sections")
        try check(try DictionaryResponse.parse("```json\n{\"sameLanguage\":true}\n```") == .sameLanguage,
                  "The same single-fence compatibility applies to a same-language result")
        try reject("{\"sameLanguage\":true}", "A same-language sentinel must not masquerade as a dictionary entry")
        for invalid in ["{\"sameLanguage\":false}", "{\"sameLanguage\":\"true\"}",
                        "{\"sameLanguage\":1}", "{\"sameLanguage\":null}",
                        "{\"sameLanguage\":true,\"meaning\":\"dog\"}", "true"] {
            try rejectResponse(invalid, "Only a standalone JSON true Boolean is a valid sentinel: \(invalid)")
        }
        var mixedSentinel = arabic
        mixedSentinel["sameLanguage"] = true
        try rejectResponse(json(mixedSentinel), "A complete entry and sentinel cannot be combined")
        for word in ["run", "dog"] {
            let messages = TranslationRequest.dictionaryMessages(word: word, targetLanguage: "英语")
            try check(messages.last?.content == word,
                      "A short same-language word must still use the exact selected source")
            try check(try DictionaryResponse.parse("{\"sameLanguage\":true}") == .sameLanguage,
                      "The model may skip an English target even when local detection was uncertain for \(word)")
        }
        print("Dictionary routing and structured Arabic/Korean entry checks passed; no network used.")
    }
}
