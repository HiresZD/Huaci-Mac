import Foundation

/// A failed or cancelled turn remains visible, but is never silently sent as
/// completed context in the next request. Nothing in this state is persisted.
struct ConversationState {
    enum TurnState: Equatable { case generating, complete, failed, cancelled }
    struct Turn {
        let user: String
        var answer = ""
        var state: TurnState = .generating
        var error: String?
    }

    private(set) var turns: [Turn] = []

    var isGenerating: Bool { turns.last?.state == .generating }
    var canRetry: Bool { turns.last?.state == .failed || turns.last?.state == .cancelled }
    var isError: Bool { turns.last?.state == .failed }
    var pendingUser: String? {
        guard let last = turns.last, last.state != .complete else { return nil }
        return last.user
    }
    var pendingAnswer: String { pendingUser == nil ? "" : (turns.last?.answer ?? "") }

    var status: String {
        guard let last = turns.last else { return "输入问题后发送；⌘↩ 发送，回车换行。" }
        switch last.state {
        case .generating: return "正在生成…"
        case .complete: return "已完成，可以继续提问。"
        case .failed: return last.error ?? "请求失败，可重试；本轮未加入后续上下文。"
        case .cancelled: return "已停止。可以重试或发送新问题；未完成的本轮不会加入上下文。"
        }
    }

    var completedMessages: [ChatMessage] {
        turns.filter { $0.state == .complete }.flatMap {
            [ChatMessage(role: "user", content: $0.user), ChatMessage(role: "assistant", content: $0.answer)]
        }
    }

    /// This presentation history includes a clear mark on interrupted turns.
    /// API requests use completedMessages instead.
    var displayMessages: [ChatMessage] {
        let history = pendingUser == nil ? turns[...] : turns.dropLast()
        return history.flatMap { turn in
            let suffix = turn.state == .complete ? "" : "\n\n[本轮未完成，未加入后续上下文]"
            return [ChatMessage(role: "user", content: turn.user),
                    ChatMessage(role: "assistant", content: turn.answer + suffix)]
        }
    }

    mutating func begin(question: String) throws {
        guard !isGenerating else { throw AssistantAPIError("请先停止或等待当前回答。") }
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AssistantAPIError("请输入问题。")
        }
        guard question.count <= 20_000 else { throw AssistantAPIError("问题超过 20,000 个字符，请缩短后发送。") }
        let candidate = makeMessages(for: question)
        guard candidate.reduce(0, { $0 + $1.content.count }) <= 100_000 else {
            throw AssistantAPIError("这段对话已达到上下文上限，请点击「清除记录」后提问。")
        }
        turns.append(Turn(user: question))
    }

    /// An explicit Ask AI click starts a fresh conversation and sends the selected
    /// question immediately. Validate first, so invalid input cannot interrupt the
    /// old turn or erase any of its history.
    /// AppDelegate cancels the old network task once this transition succeeds.
    mutating func beginSelection(question: String) throws {
        var next = ConversationState()
        try next.begin(question: question)
        self = next
    }

    mutating func retry() throws {
        guard canRetry, !turns.isEmpty else { throw AssistantAPIError("没有可重试的请求。") }
        turns[turns.count - 1].answer = ""
        turns[turns.count - 1].error = nil
        turns[turns.count - 1].state = .generating
    }

    mutating func append(_ text: String) {
        guard isGenerating else { return }
        turns[turns.count - 1].answer += text
    }

    mutating func complete() {
        guard isGenerating else { return }
        if turns[turns.count - 1].answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            fail("模型没有返回正文，请检查设置后重试。")
        } else {
            turns[turns.count - 1].state = .complete
        }
    }

    mutating func fail(_ message: String) {
        guard isGenerating else { return }
        turns[turns.count - 1].state = .failed
        turns[turns.count - 1].error = message + "\n本轮未完成，未加入后续上下文。"
    }

    mutating func cancel() {
        guard isGenerating else { return }
        turns[turns.count - 1].state = .cancelled
    }

    mutating func clear() { turns.removeAll() }

    func requestMessages() throws -> [ChatMessage] {
        guard isGenerating, let pending = pendingUser else { throw AssistantAPIError("没有待发送的问题。") }
        return makeMessages(for: pending)
    }

    private func makeMessages(for question: String) -> [ChatMessage] {
        var result = APIClient.messages(mode: .ask, text: question)
        result.insert(contentsOf: completedMessages, at: 1)
        return result
    }
}
