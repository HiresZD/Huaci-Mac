import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private actor Requests {
    private var recorded: [[ChatMessage]] = []

    func record(_ messages: [ChatMessage]) -> Int {
        recorded.append(messages)
        return recorded.count
    }

    func all() -> [[ChatMessage]] { recorded }
}

@main
struct DictionaryServiceRegression {
    static let valid = """
    {"sourceLanguage":"en","pronunciation":"/ˈæpəl/","senses":[{"partOfSpeech":"名词","meaning":"苹果；苹果树结出的果实"}],"collocations":[{"text":"apple juice","translation":"苹果汁"}],"examples":[{"text":"She ate an apple.","translation":"她吃了一个苹果。"}]}
    """

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    static func main() async throws {
        // No network calls or credentials are used. The same lookup function
        // used by the app runs against deterministic transport responses.
        let successful = Requests()
        let result = try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
            _ = await successful.record(messages)
            return valid
        }
        let expectedEntry = try DictionaryEntry.parse(valid)
        try expect(result == .entry(expectedEntry), "A valid entry must survive lookup unchanged")
        let successRequests = await successful.all()
        try expect(successRequests.count == 1, "Valid output must not cause a repair request")

        let repaired = Requests()
        let recovered = try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
            let number = await repaired.record(messages)
            return number == 1 ? "苹果" : valid
        }
        try expect(recovered == result, "A bare translation must be replaced by a complete validated dictionary")
        let repairRequests = await repaired.all()
        try expect(repairRequests.count == 2, "Invalid dictionary output gets exactly one repair")
        try expect(repairRequests[0] == TranslationRequest.dictionaryMessages(word: "apple", targetLanguage: "简体中文"),
                   "First attempt uses the normal dictionary prompt")
        try expect(repairRequests[1] == TranslationRequest.dictionaryMessages(word: "apple", targetLanguage: "简体中文", repair: true),
                   "Repair regenerates a complete entry from the original source and target")

        let invalid = Requests()
        do {
            _ = try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
                _ = await invalid.record(messages)
                return "{\"sourceLanguage\":\"en\",\"pronunciation\":null,\"senses\":[],\"collocations\":[],\"examples\":[]}"
            }
            throw TestFailure(description: "Two invalid replies must fail instead of displaying an incomplete entry")
        } catch is DictionaryEntryError { }
        let invalidRequests = await invalid.all()
        try expect(invalidRequests.count == 2, "Repeated invalid output must terminate after two attempts")

        let network = Requests()
        do {
            _ = try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
                _ = await network.record(messages)
                throw URLError(.timedOut)
            }
            throw TestFailure(description: "Transport failure must propagate")
        } catch let error as URLError {
            try expect(error.code == .timedOut, "Transport error must retain its original cause")
        }
        let networkRequests = await network.all()
        try expect(networkRequests.count == 1, "Network errors must not trigger automatic repair requests")

        let api = Requests()
        do {
            _ = try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
                _ = await api.record(messages)
                throw AssistantAPIError("test API failure")
            }
            throw TestFailure(description: "API failure must propagate")
        } catch is AssistantAPIError { }
        let apiRequests = await api.all()
        try expect(apiRequests.count == 1, "API errors must not trigger automatic repair requests")

        let cancelled = Requests()
        let lookupTask = Task {
            try await DictionaryService.lookup(word: "apple", targetLanguage: "简体中文") { messages in
                _ = await cancelled.record(messages)
                // Emulate a transport finishing with invalid data just as the
                // user changes languages. Cancellation still prevents repair.
                withUnsafeCurrentTask { $0?.cancel() }
                return "苹果"
            }
        }
        do {
            _ = try await lookupTask.value
            throw TestFailure(description: "Cancelled lookup must not render or repair its result")
        } catch is CancellationError { }
        let cancelledRequests = await cancelled.all()
        try expect(cancelledRequests.count == 1, "Cancellation after a response must prevent repair")

        let same = Requests()
        let sameLanguage = try await DictionaryService.lookup(word: "apple", targetLanguage: "英语 English") { messages in
            _ = await same.record(messages)
            return "{\"sameLanguage\":true}"
        }
        try expect(sameLanguage == .sameLanguage, "Same-language output must preserve the no-translation behavior")
        let sameRequests = await same.all()
        try expect(sameRequests.count == 1, "Same-language result must not trigger a repair")

        let switching = Requests()
        for target in ["阿拉伯语 العربية", "韩语 한국어", "简体中文"] {
            let translated = try await DictionaryService.lookup(word: "apple", targetLanguage: target) { messages in
                _ = await switching.record(messages)
                return valid
            }
            try expect(translated == result, "Every target retains the structured dictionary mode")
        }
        let switchingRequests = await switching.all()
        try expect(switchingRequests.count == 3, "Independent successful target lookups need one request each")
        for (messages, target) in zip(switchingRequests, ["阿拉伯语 العربية", "韩语 한국어", "简体中文"]) {
            try expect(messages == TranslationRequest.dictionaryMessages(word: "apple", targetLanguage: target),
                       "Switching targets starts from the same original word and the current target, with no old output")
        }
        print("Dictionary lookup policy regression checks passed (no network used).")
    }
}
