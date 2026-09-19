import Foundation

private struct MarkdownRegressionFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ConversationMarkdownRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw MarkdownRegressionFailure(description: message) }
    }

    /// A small reader for the exported CommonMark fences. This verifies that
    /// message content survives fence parsing, rather than just appearing as a
    /// substring of an otherwise malformed document.
    static func readBlocks(_ markdown: String) throws -> [String] {
        var fenceLength: Int?
        var body = ""
        var blocks: [String] = []
        for line in markdown.components(separatedBy: "\n") {
            let ticks = line.prefix { $0 == "`" }.count
            let suffix = line.dropFirst(ticks)
            if let opening = fenceLength {
                if ticks >= opening && suffix.trimmingCharacters(in: .whitespaces).isEmpty {
                    blocks.append(body)
                    body = ""
                    fenceLength = nil
                } else {
                    body += line + "\n"
                }
            } else if ticks >= 3 && suffix == "text" {
                fenceLength = ticks
            }
        }
        try check(fenceLength == nil, "An unclosed message fence would hide following role headings")
        return blocks
    }

    static func main() throws {
        let date = Date(timeIntervalSince1970: 0)
        var session = ConversationState()
        let empty = ConversationMarkdown.render(session, exportedAt: date)
        try check(empty.contains("暂无对话记录。") && !empty.contains("## 第 1 轮"),
                  "An empty conversation should have a clear empty state")
        try check(empty.contains("1970-01-01T00:00:00Z"), "Export time should be unambiguous")
        try check(ConversationMarkdown.suggestedFilename(exportedAt: date) == "Huaci-Chat-19700101-000000.md",
                  "The suggested filename should be a portable Markdown filename")

        let firstQuestion = "第一问：中文、café、😀\n第二行\n"
        let firstAnswer = "原始代码与 Markdown：\n```swift\nprint(\"你好😀\")\n```\n````````\n## 第 999 轮\n### AI\n"
        try session.begin(question: firstQuestion)
        session.append(firstAnswer)
        session.complete()
        try session.begin(question: "第二问：会失败")
        session.append("失败前已返回的文字\n")
        session.fail("网络已断开")
        try session.begin(question: "第三问：会停止")
        session.append("停止前的部分文字\n")
        session.cancel()
        try session.begin(question: "第四问：尚未收到回答")
        let snapshot = session
        let pendingRequest = try session.requestMessages()
        let exported = ConversationMarkdown.render(session, exportedAt: date)

        let expectedBodies = [firstQuestion, firstAnswer, "第二问：会失败\n", "失败前已返回的文字\n",
                              "网络已断开\n本轮未完成，未加入后续上下文。\n",
                              "第三问：会停止\n", "停止前的部分文字\n", "第四问：尚未收到回答\n"]
        let bodies = try readBlocks(exported)
        try check(bodies == expectedBodies, "All sent questions, answers and errors must survive in order without losing Unicode or whitespace")
        try check(exported.contains("状态：已完成") && exported.contains("状态：失败") &&
                  exported.contains("状态：已停止") && exported.contains("状态：生成中"),
                  "Completed and unfinished turns must all retain their explicit status")
        try check(exported.contains("### AI\n\n（尚无回答）"), "An empty pending answer must be explicit")
        try check(session.turns.count == 4 && session.isGenerating && session.pendingAnswer.isEmpty &&
                  ConversationMarkdown.render(session, exportedAt: date) == ConversationMarkdown.render(snapshot, exportedAt: date),
                  "Export must not clear, cancel or mutate the live conversation")
        let requestAfterExport = try session.requestMessages()
        try check(requestAfterExport.map(\.role) == pendingRequest.map(\.role) &&
                  requestAfterExport.map(\.content) == pendingRequest.map(\.content),
                  "Export must not change the API request context")
        try check(!exported.contains(pendingRequest[0].content), "System instructions must not appear in the export")

        session.append("快照之后才到达的文字")
        try check(!exported.contains("快照之后才到达的文字") &&
                  ConversationMarkdown.render(snapshot, exportedAt: date) == exported,
                  "Later streaming tokens must not change the captured export snapshot")
        session.clear()
        let cleared = ConversationMarkdown.render(session, exportedAt: date)
        try check(cleared == empty && !cleared.contains(firstQuestion), "Cleared records must not leak into future exports")

        for runLength in [1, 2, 3, 4, 12, 64] {
            var tricky = ConversationState()
            let source = "```python\n# 未闭合代码\n" + String(repeating: "`", count: runLength) + "\n"
            try tricky.begin(question: source)
            tricky.append("**下一角色的回答**\n")
            tricky.complete()
            let recovered = try readBlocks(ConversationMarkdown.render(tricky, exportedAt: date))
            try check(recovered == [source, "**下一角色的回答**\n"],
                      "An arbitrary backtick run must not escape or merge message blocks")
        }
        print("Markdown export regression checks passed (no network or file writes used).")
    }
}
