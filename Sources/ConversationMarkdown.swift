import Foundation

/// Exports a value snapshot of the visible sent turns. Provider settings,
/// instruction messages and the unsent composer are deliberately not inputs.
enum ConversationMarkdown {
    static func render(_ conversation: ConversationState, exportedAt: Date = Date()) -> String {
        let timestamp = ISO8601DateFormatter().string(from: exportedAt)
        var sections = ["# 划词助手对话记录", "导出时间：\(timestamp)"]

        guard !conversation.turns.isEmpty else {
            sections.append("暂无对话记录。")
            return sections.joined(separator: "\n\n") + "\n"
        }

        for (index, turn) in conversation.turns.enumerated() {
            sections.append("## 第 \(index + 1) 轮")
            let status: String
            switch turn.state {
            case .complete: status = "已完成"
            case .generating: status = "生成中（导出时的快照，本轮尚未完成）"
            case .failed: status = "失败（本轮未完成，未加入后续上下文）"
            case .cancelled: status = "已停止（本轮未完成，未加入后续上下文）"
            }
            sections.append("状态：\(status)")
            sections.append("### 用户\n\n" + literalBlock(turn.user))
            if turn.answer.isEmpty {
                sections.append("### AI\n\n（尚无回答）")
            } else {
                sections.append("### AI\n\n" + literalBlock(turn.answer))
            }
            if let error = turn.error, !error.isEmpty {
                sections.append("### 错误说明\n\n" + literalBlock(error))
            }
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func suggestedFilename(exportedAt: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "Huaci-Chat-\(formatter.string(from: exportedAt)).md"
    }

    /// AppKit currently presents message bodies as plain text. Keep that same
    /// content intact in Markdown, including original Markdown/code syntax.
    /// A longer fence than any backtick run prevents an unfinished code block
    /// in one message from swallowing the next role or conversation heading.
    private static func literalBlock(_ text: String) -> String {
        var longestRun = 0
        var currentRun = 0
        for byte in text.utf8 {
            if byte == 0x60 {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        let terminator = text.hasSuffix("\n") ? "" : "\n"
        return fence + "text\n" + text + terminator + fence
    }
}
