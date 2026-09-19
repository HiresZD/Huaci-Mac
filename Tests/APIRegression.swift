import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct APIRegression {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TestFailure(description: message) }
    }

    static func expectThrows(_ label: String, _ action: () throws -> Void) throws {
        do { try action() }
        catch is AssistantAPIError { return }
        throw TestFailure(description: "Expected validation to reject: \(label)")
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        guard let data = request.httpBody,
              let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TestFailure(description: "Request body is not JSON")
        }
        return body
    }

    static func main() throws {
        // No network calls or real credentials are used by this executable.
        let deepseek = try APIConfiguration.validated(
            baseURL: "https://api.deepseek.com/", apiKey: "test-key", model: "deepseek-flash")
        try expect(deepseek.endpoint.absoluteString == "https://api.deepseek.com/chat/completions",
                   "DeepSeek bare host must use the canonical endpoint")
        let explicitV1 = try APIConfiguration.validated(
            baseURL: "https://api.deepseek.com/v1", apiKey: "test-key", model: "deepseek-flash")
        try expect(explicitV1.endpoint.path == "/v1/chat/completions", "Explicit v1 path must remain valid")
        let fullEndpoint = try APIConfiguration.validated(
            baseURL: "https://api.deepseek.com/chat/completions/", apiKey: "test-key", model: "deepseek-flash")
        try expect(fullEndpoint.endpoint == deepseek.endpoint, "Full endpoint must not be duplicated")

        let translation = APIClient.messages(mode: .translate, text: "Good morning.")
        try expect(translation.count == 2 && translation[0].role == "system" && translation[1].role == "user",
                   "Translation must provide separate system and source messages")
        try expect(translation[0].content.contains("简体中文"), "Translation defaults to simplified Chinese")
        try expect(translation[0].content.contains("自动识别原文语言"), "Translation auto-detects the source language")
        try expect(translation[1].content == "Good morning.", "Translation must preserve the selected source")
        let english = APIClient.messages(mode: .translate, text: "早上好。", targetLanguage: "英语 English")
        try expect(english[0].content.contains("目标语言：英语 English"), "Selected target reaches the translation prompt")
        try expect(english[0].content.contains("用目标语言"), "Dictionary explanations use the chosen target language")

        var history = APIClient.messages(mode: .ask, text: "DeepSeek-V4.1-Flash")
        try expect(history[0].content.contains("默认用简体中文回答"), "Questions default to Chinese")
        try expect(history[0].content.contains("术语、名称或短语"), "Lone selected terms should be explained")
        try expect(history[0].content.contains("不要根据名称"), "Prompt must not invent model identity")
        history.append(ChatMessage(role: "assistant", content: "这是模型的名称。"))
        history.append(ChatMessage(role: "user", content: "请再解释一下 Flash 的含义。"))
        let request = try APIClient.makeRequest(configuration: deepseek, messages: history)
        let requestBody = try body(request)
        try expect(request.httpMethod == "POST", "Chat requests must use POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key", "Key belongs in Authorization header")
        try expect(requestBody["model"] as? String == "deepseek-flash", "Requested model must be preserved")
        try expect(requestBody["stream"] as? Bool == true, "Request must enable streaming")
        try expect((requestBody["thinking"] as? [String: String])?["type"] == "disabled",
                   "Official DeepSeek must explicitly disable thinking for fast selection actions")
        try expect(requestBody["response_format"] == nil && requestBody["max_tokens"] == nil,
                   "Ordinary chat must retain its existing response format and token policy")
        for target in ["阿拉伯语", "韩语", "简体中文"] {
            let dictionary = TranslationRequest.dictionaryMessages(word: "apple", targetLanguage: target)
            let dictionaryBody = try body(APIClient.makeRequest(configuration: deepseek,
                                                                messages: dictionary, structuredDictionary: true))
            try expect((dictionaryBody["response_format"] as? [String: String])?["type"] == "json_object",
                       "DeepSeek dictionary requests must enable JSON output for every target")
            try expect(dictionaryBody["max_tokens"] as? Int == 4096,
                       "A full dictionary needs an explicit completion budget")
            let encoded = try JSONSerialization.data(withJSONObject: dictionaryBody["messages"]!)
            let decoded = try JSONDecoder().decode([ChatMessage].self, from: encoded)
            try expect(decoded == dictionary && decoded.last?.content == "apple",
                       "Target switches must serialize the original word and fresh dictionary instructions")
        }
        let translationBody = try body(APIClient.makeRequest(configuration: deepseek, messages: translation))
        try expect(translationBody["response_format"] == nil, "Sentence translations remain plain text")
        guard let rawMessages = requestBody["messages"] else {
            throw TestFailure(description: "Request has no messages")
        }
        let encodedMessages = try JSONSerialization.data(withJSONObject: rawMessages)
        let decodedMessages = try JSONDecoder().decode([ChatMessage].self, from: encodedMessages)
        try expect(decodedMessages == history, "Full ordered system, user and assistant history must survive serialization")
        try expect(decodedMessages.filter { $0.role == "system" }.count == 1, "Follow-up must not duplicate system instructions")

        for host in ["api.example.com", "api.deepseek.com.example.com"] {
            let generic = try APIConfiguration.validated(
                baseURL: "https://\(host)", apiKey: "test-key", model: "custom-model")
            try expect(generic.endpoint.path == "/v1/chat/completions", "Generic bare hosts must retain v1 routing")
            let genericBody = try body(APIClient.makeRequest(configuration: generic, messages: history))
            try expect(genericBody["thinking"] == nil, "Provider-specific fields must be restricted to the exact DeepSeek host")
            let genericDictionary = try body(APIClient.makeRequest(configuration: generic,
                messages: TranslationRequest.dictionaryMessages(word: "apple", targetLanguage: "韩语"),
                structuredDictionary: true))
            try expect(genericDictionary["response_format"] == nil && genericDictionary["max_tokens"] == nil,
                       "Generic endpoints must not receive optional DeepSeek dictionary parameters")
        }
        let local = try APIConfiguration.validated(baseURL: "http://localhost:8080/v1", apiKey: "", model: "local")
        let localRequest = try APIClient.makeRequest(configuration: local, messages: history)
        try expect(localRequest.value(forHTTPHeaderField: "Authorization") == nil, "Local unauthenticated endpoint must omit Authorization")
        try expectThrows("public HTTP") {
            _ = try APIConfiguration.validated(baseURL: "http://api.example.com", apiKey: "test-key", model: "x")
        }
        try expectThrows("URL query") {
            _ = try APIConfiguration.validated(baseURL: "https://api.deepseek.com/?key=test", apiKey: "test-key", model: "x")
        }
        try expectThrows("header injection") {
            _ = try APIConfiguration.validated(baseURL: "https://api.deepseek.com", apiKey: "test\nkey", model: "x")
        }
        try expectThrows("empty user input") {
            _ = try APIClient.makeRequest(configuration: deepseek, messages: APIClient.messages(mode: .ask, text: " \n "))
        }
        try expectThrows("oversized single user input") {
            _ = try APIClient.makeRequest(configuration: deepseek,
                                          messages: APIClient.messages(mode: .ask, text: String(repeating: "文", count: 20_001)))
        }
        try expectThrows("oversized complete history") {
            var oversized = APIClient.messages(mode: .ask, text: "第一问")
            oversized.append(ChatMessage(role: "assistant", content: String(repeating: "文", count: 100_000)))
            oversized.append(ChatMessage(role: "user", content: "第二问"))
            _ = try APIClient.makeRequest(configuration: deepseek, messages: oversized)
        }
        try expectThrows("duplicate system message") {
            var duplicate = history
            duplicate.insert(history[0], at: 1)
            _ = try APIClient.makeRequest(configuration: deepseek, messages: duplicate)
        }
        try expectThrows("unsupported role") {
            var invalid = history
            invalid.insert(ChatMessage(role: "tool", content: "unsupported"), at: 1)
            _ = try APIClient.makeRequest(configuration: deepseek, messages: invalid)
        }
        print("API request regression checks passed (no network used).")
    }
}
