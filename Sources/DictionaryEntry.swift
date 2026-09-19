import Foundation

struct DictionaryEntryError: LocalizedError {
    var errorDescription: String? {
        "模型未返回完整的词典解释，请重试；无法确认的词汇不会编造释义。"
    }
}

enum DictionaryResponse: Equatable {
    case entry(DictionaryEntry)
    case sameLanguage

    static func parse(_ response: String) throws -> DictionaryResponse {
        let data = try DictionaryEntry.responseData(from: response)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DictionaryEntryError()
        }
        if object.keys.contains("sameLanguage") {
            // JSONDecoder's Bool decoding is strict: a number or the string
            // "true" is not a Bool. A sentinel mixed with entry fields is invalid.
            guard object.count == 1,
                  let flag = try? JSONDecoder().decode(SameLanguageFlag.self, from: data),
                  flag.sameLanguage else { throw DictionaryEntryError() }
            return .sameLanguage
        }
        return .entry(try DictionaryEntry.parse(response))
    }

    private struct SameLanguageFlag: Decodable {
        let sameLanguage: Bool
    }
}

/// A successful lookup always has every dictionary section. Display formatting
/// belongs to the app, so a target-language change cannot change the layout.
struct DictionaryEntry: Equatable, Codable {
    struct Sense: Equatable, Codable {
        let partOfSpeech: String
        let meaning: String
    }

    struct Example: Equatable, Codable {
        let text: String
        let translation: String
    }

    let sourceLanguage: String
    let pronunciation: String?
    let senses: [Sense]
    let collocations: [Example]
    let examples: [Example]

    static let maximumResponseBytes = 65_536

    /// A complete, searchable version for history and Markdown export.
    func plainText(word: String) -> String {
        let meanings = senses.map { "\($0.partOfSpeech)\n\($0.meaning)" }.joined(separator: "\n\n")
        let combinations = collocations.map { "\($0.text)\n\($0.translation)" }.joined(separator: "\n\n")
        let sentences = examples.map { "\($0.text)\n\($0.translation)" }.joined(separator: "\n\n")
        return "\(word)\n音标  \(pronunciation ?? "暂无可靠音标")\n\n词性与释义\n\(meanings)\n\n常见搭配\n\(combinations)\n\n例句\n\(sentences)"
    }

    fileprivate static func responseData(from response: String) throws -> Data {
        guard response.utf8.count <= maximumResponseBytes else { throw DictionaryEntryError() }
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some compatible providers wrap JSON despite the prompt. Accept exactly
        // one complete JSON fence, never extract a fragment from surrounding prose.
        if json.hasPrefix("```") {
            guard let newline = json.firstIndex(of: "\n") else { throw DictionaryEntryError() }
            let opening = json[..<newline].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard opening == "```json" || opening == "```", json.hasSuffix("```") else {
                throw DictionaryEntryError()
            }
            let body = json[json.index(after: newline)..<json.index(json.endIndex, offsetBy: -3)]
            json = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !json.contains("```") else { throw DictionaryEntryError() }
        }

        guard let data = json.data(using: .utf8) else { throw DictionaryEntryError() }
        return data
    }

    static func parse(_ response: String) throws -> DictionaryEntry {
        let data = try responseData(from: response)
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              (2...3).contains(decoded.sourceLanguage.utf8.count),
              decoded.sourceLanguage.utf8.allSatisfy({ (97...122).contains($0) }),
              (1...8).contains(decoded.senses.count),
              (1...5).contains(decoded.collocations.count),
              (1...4).contains(decoded.examples.count) else {
            throw DictionaryEntryError()
        }
        let pronunciation: String?
        if let value = decoded.pronunciation {
            pronunciation = try required(value, maximumLength: 256)
        } else {
            pronunciation = nil
        }
        let senses = try decoded.senses.map {
            Sense(partOfSpeech: try required($0.partOfSpeech, maximumLength: 100),
                  meaning: try required($0.meaning, maximumLength: 2_000))
        }
        let collocations = try decoded.collocations.map { try validated($0) }
        let examples = try decoded.examples.map { try validated($0) }
        return DictionaryEntry(sourceLanguage: decoded.sourceLanguage, pronunciation: pronunciation, senses: senses,
                               collocations: collocations, examples: examples)
    }

    private static func required(_ value: String, maximumLength: Int) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= maximumLength,
              !result.unicodeScalars.contains(where: {
                  ($0.value < 32 && $0.value != 9 && $0.value != 10 && $0.value != 13) || $0.value == 127
              }) else { throw DictionaryEntryError() }
        return result
    }

    private static func validated(_ example: Example) throws -> Example {
        Example(text: try required(example.text, maximumLength: 2_000),
                translation: try required(example.translation, maximumLength: 2_000))
    }

    private struct Response: Decodable {
        let sourceLanguage: String
        let pronunciation: String?
        let senses: [Sense]
        let collocations: [Example]
        let examples: [Example]

        private enum CodingKeys: String, CodingKey {
            case sourceLanguage, pronunciation, senses, collocations, examples
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
            // nil is an explicit "cannot verify IPA", not permission to omit the
            // field. The UI keeps its pronunciation row visible in either case.
            guard container.contains(.pronunciation) else { throw DictionaryEntryError() }
            pronunciation = try container.decodeIfPresent(String.self, forKey: .pronunciation)
            senses = try container.decode([Sense].self, forKey: .senses)
            collocations = try container.decode([Example].self, forKey: .collocations)
            examples = try container.decode([Example].self, forKey: .examples)
        }
    }
}
