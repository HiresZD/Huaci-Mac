import Foundation

/// Dictionary responses are rendered only after their complete structure has
/// been validated. Each lookup owns its messages and buffer; a previous target
/// language or failed response can never select the next lookup's mode.
enum DictionaryService {
    static func lookup(configuration: APIConfiguration, word: String, targetLanguage: String,
                       onModel: @escaping (String) async -> Void = { _ in }) async throws -> DictionaryResponse {
        try await lookup(word: word, targetLanguage: targetLanguage) { messages in
            let buffer = DictionaryResponseBuffer()
            try await APIClient.stream(configuration: configuration, messages: messages,
                                       structuredDictionary: true, onModel: onModel,
                                       onDelta: { delta in await buffer.append(delta) })
            try Task.checkCancellation()
            return try await buffer.response()
        }
    }

    /// The injectable transport exercises the actual repair policy without
    /// network requests. Only a completed, invalid dictionary response is
    /// eligible for one repair; transport and cancellation errors propagate.
    static func lookup(word: String, targetLanguage: String,
                       request: ([ChatMessage]) async throws -> String) async throws -> DictionaryResponse {
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let messages = TranslationRequest.dictionaryMessages(
                word: word, targetLanguage: targetLanguage, repair: attempt == 1)
            let response = try await request(messages)
            try Task.checkCancellation()
            do {
                return try DictionaryResponse.parse(response)
            } catch is DictionaryEntryError {
                try Task.checkCancellation()
                if attempt == 1 { throw DictionaryEntryError() }
            }
        }
        throw DictionaryEntryError()
    }
}

private actor DictionaryResponseBuffer {
    private var text = ""
    private var byteCount = 0
    private var exceededLimit = false

    func append(_ delta: String) {
        guard !exceededLimit else { return }
        let deltaBytes = delta.utf8.count
        guard deltaBytes <= DictionaryEntry.maximumResponseBytes - byteCount else {
            exceededLimit = true
            text.removeAll(keepingCapacity: false)
            return
        }
        byteCount += deltaBytes
        text += delta
    }

    func response() throws -> String {
        guard !exceededLimit else {
            throw AssistantAPIError("接口返回的词典内容过长，请重试。")
        }
        return text
    }
}
