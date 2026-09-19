import Foundation

private struct RegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ConversationRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw RegressionFailure(description: message) }
    }

    static func main() throws {
        var session = ConversationState()
        try session.begin(question: "解释 Flash 的含义")
        var messages = try session.requestMessages()
        try check(messages.map(\.role) == ["system", "user"], "First turn must contain only one instruction and one question")
        session.append("Flash 通常表示快速或闪光，具体含义取决于上下文。")
        session.complete()
        try check(!session.isGenerating && !session.canRetry, "A completed turn must not remain pending")

        try session.begin(question: "请举一个例子")
        messages = try session.requestMessages()
        try check(messages.map(\.role) == ["system", "user", "assistant", "user"], "Follow-up must preserve the completed exchange")
        try check(messages[1].content == "解释 Flash 的含义", "First question missing from context")
        try check(messages[2].content.contains("上下文"), "Previous answer missing from context")
        session.append("暂未完成的答案")
        session.cancel()
        try check(session.canRetry && session.pendingAnswer == "暂未完成的答案", "Cancelled output must remain visible")
        session.append("迟到的回调")
        try check(!session.pendingAnswer.contains("迟到"), "Cancelled turn must reject late tokens")
        try session.retry()
        try check(session.pendingAnswer.isEmpty && session.turns.count == 2, "Retry must replace rather than duplicate the pending turn")
        messages = try session.requestMessages()
        try check(messages.filter { $0.content == "请举一个例子" }.count == 1, "Retry must send the last question exactly once")
        session.fail("模拟网络断开")

        try session.begin(question: "那再用英语解释一次")
        messages = try session.requestMessages()
        try check(messages.map(\.role) == ["system", "user", "assistant", "user"], "Failed turn must not enter wire history")
        try check(!messages.contains { $0.content == "请举一个例子" }, "Failed question unexpectedly sent as context")
        try check(session.displayMessages.contains { $0.content.contains("未加入后续上下文") }, "Failed turn must be marked in visible history")
        session.append("An example.")
        session.complete()
        session.clear()
        try check(session.turns.isEmpty && session.pendingUser == nil, "Clearing records must remove all sent context")

        // Each explicit selection submits immediately into a fresh conversation.
        // Invalid input must leave the current conversation and response intact.
        try session.beginSelection(question: "第一段选中文字")
        session.append("已完成的解释")
        session.complete()
        try session.begin(question: "尚在生成的追问")
        session.append("未完成的片段")
        for invalidSelection in [" \n\t", String(repeating: "字", count: 20_001)] {
            do {
                try session.beginSelection(question: invalidSelection)
                throw RegressionFailure(description: "Invalid selection must be rejected")
            } catch is AssistantAPIError {}
            try check(session.isGenerating && session.pendingUser == "尚在生成的追问",
                      "Rejected selection must not cancel the current response")
            try check(session.pendingAnswer == "未完成的片段" && session.turns.count == 2,
                      "Rejected selection must retain the partial answer and turn count")
            try check(session.completedMessages.map(\.content) == ["第一段选中文字", "已完成的解释"],
                      "Rejected selection must retain completed conversation history")
        }
        try session.beginSelection(question: "新的划词问题")
        messages = try session.requestMessages()
        try check(messages.map(\.role) == ["system", "user"],
                  "Immediate selection must start without previous conversation context")
        try check(messages.last?.content == "新的划词问题" &&
                  messages.filter { $0.content == "新的划词问题" }.count == 1,
                  "Selected text must be submitted exactly once")
        try check(!messages.contains { $0.content == "尚在生成的追问" || $0.content == "未完成的片段" },
                  "Interrupted answer and question must not enter the new request")
        try check(session.turns.count == 1 && session.turns[0].user == "新的划词问题" &&
                  session.displayMessages.isEmpty && session.completedMessages.isEmpty,
                  "New selection must remove completed and interrupted turns from visible and wire history")
        session.append("新回答")
        session.complete()
        try session.begin(question: "手动发送的后续问题")
        messages = try session.requestMessages()
        try check(messages.map(\.role) == ["system", "user", "assistant", "user"] &&
                  messages.dropFirst().map(\.content) == ["新的划词问题", "新回答", "手动发送的后续问题"],
                  "Manual follow-up must include only the new conversation's completed exchange")
        session.append("追问回答")
        session.complete()
        try session.beginSelection(question: "另一段选中文字")
        messages = try session.requestMessages()
        try check(session.turns.count == 1 && messages.count == 2 && messages.last?.content == "另一段选中文字",
                  "A new selection after a completed conversation must also discard the previous history")
        session.append("尚未完成的第三段回答")
        session.clear()
        session.append("清除后的迟到回调")
        session.complete()
        session.fail("清除后的迟到错误")
        session.cancel()
        do {
            try session.retry()
            throw RegressionFailure(description: "Cleared conversation must not be retryable")
        } catch is AssistantAPIError {}
        try check(session.turns.isEmpty && session.displayMessages.isEmpty && session.completedMessages.isEmpty &&
                  session.pendingUser == nil && session.pendingAnswer.isEmpty && !session.isGenerating && !session.canRetry,
                  "Late callbacks and retry must not restore cleared records")

        let oldData = Data(#"{"baseURL":"https://api.deepseek.com/chat/completions","model":"deepseek-flash","enabled":false}"#.utf8)
        let oldSettings = try JSONDecoder().decode(AppSettings.self, from: oldData)
        try check(oldSettings.model == "deepseek-flash" && !oldSettings.enabled, "Upgrade must preserve existing provider/model/switch")
        try check(oldSettings.translationTarget == "zh-CN", "Old settings should receive a Chinese translation default")
        try check(!oldSettings.popupAfterCopy && !AppSettings().popupAfterCopy,
                  "Copy compatibility must remain opt-in on new installs and upgrades")
        var languageSettings = oldSettings
        languageSettings.translationTarget = TranslationLanguage.english.rawValue
        languageSettings.popupAfterCopy = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(languageSettings))
        try check(roundTrip.translationTarget == "en", "Target language should survive encode/decode")
        try check(roundTrip.popupAfterCopy && roundTrip.model == oldSettings.model && !roundTrip.enabled,
                  "Compatibility preference must persist without changing existing configuration")
        for language in TranslationLanguage.allCases {
            let translation = APIClient.messages(mode: .translate, text: "Example.", targetLanguage: language.instructionName)
            try check(translation[0].content.contains("目标语言：" + language.instructionName), "A selected language failed to reach the request prompt")
        }
        print("Conversation and settings migration regression checks passed (no network or Keychain access used).")
    }
}
