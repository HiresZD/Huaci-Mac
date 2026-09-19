import AppKit
import UniformTypeIdentifiers

private final class ChatInputTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if (event.keyCode == 36 || event.keyCode == 76),
           modifiers.contains(.command), !modifiers.contains(.control), !modifiers.contains(.option),
           !hasMarkedText() {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Presents a conversation. Request lifetime and conversation history belong to AppDelegate.
@MainActor
final class ChatWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    var onSend: ((String) -> Void)?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onClear: (() -> Void)?
    var onExport: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let transcript = NSTextView(frame: NSRect(x: 0, y: 0, width: 564, height: 330))
    private let transcriptScroll = NSScrollView()
    private let input = ChatInputTextView(frame: NSRect(x: 0, y: 0, width: 564, height: 90))
    private let inputScroll = NSScrollView()
    private let modelLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "输入问题或继续追问；⌘↩ 发送。")
    private let sendButton = NSButton(title: "发送", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制回答", target: nil, action: nil)
    private let clearButton = NSButton(title: "清除记录", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出记录", target: nil, action: nil)
    private var presetButtons: [NSButton] = []
    private var presetDraft = AIPresetDraftState()
    private var hasRecords = false
    private var exporting = false
    private var generating = false
    private var lastAnswer = ""
    private var wasPresented = false

    var isVisible: Bool { window?.isVisible == true }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        super.init(window: window)
        window.title = "划词助手 · 问 AI"
        window.minSize = NSSize(width: 480, height: 480)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.delegate = self
        buildInterface()
        setModelInfo(requested: "未设置", returned: nil, endpointHost: "未设置")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(draft: String? = nil, near point: NSPoint? = nil) {
        if let draft { appendDraft(draft) }
        guard let window else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        if !wasPresented, point == nil { window.center() }
        fitOnScreen(near: point)
        wasPresented = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(input)
    }

    /// Keep a selection editable when an immediate submission could not be accepted.
    func appendDraft(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        presetDraft.resetGeneratedDraft()
        if input.string.isEmpty {
            input.string = text
        } else {
            input.string += "\n\n" + text
        }
        input.setSelectedRange(NSRange(location: input.string.utf16.count, length: 0))
        input.scrollRangeToVisible(input.selectedRange())
        updateSendButton()
    }

    func resetDraft() {
        input.string = ""
        presetDraft.resetGeneratedDraft()
        updateSendButton()
    }

    /// New selections change the empty-input fallback without overwriting a
    /// follow-up the user may already be composing. Pass an empty string on clear.
    func setSelectionContext(_ text: String) {
        presetDraft.setSelectionContext(text)
        updateSendButton()
    }

    /// The caller supplies a snapshot taken when Export is clicked. A response
    /// can continue streaming while the user chooses the destination.
    func exportMarkdown(_ markdown: String, suggestedFilename: String) {
        guard let window, !exporting else { return }
        exporting = true
        updateRecordButtons()
        let savePanel = NSSavePanel()
        savePanel.title = "导出对话记录"
        savePanel.prompt = "导出"
        savePanel.message = "保存点击「导出记录」时的当前对话；不会包含尚未发送的草稿。"
        savePanel.nameFieldStringValue = suggestedFilename
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowsOtherFileTypes = false
        let markdownType = UTType(filenameExtension: "md", conformingTo: .plainText)
            ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
        savePanel.allowedContentTypes = [markdownType]
        savePanel.beginSheetModal(for: window) { [weak self] response in
            defer {
                self?.exporting = false
                self?.updateRecordButtons()
            }
            guard response == .OK, let url = savePanel.url else { return }
            do {
                // Write exactly the URL confirmed by the native save panel,
                // preserving its cancellation and overwrite-confirmation behavior.
                try markdown.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                guard let self, let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "知道了")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    func setModelInfo(requested: String, returned: String?, endpointHost: String) {
        let actual = returned.flatMap { $0.isEmpty ? nil : $0 } ?? "尚未提供"
        modelLabel.stringValue = "接口：\(endpointHost)\n请求模型：\(requested)  ·  返回模型：\(actual)"
        modelLabel.toolTip = modelLabel.stringValue
    }

    func render(
        messages: [ChatMessage], pendingUser: String?, pendingAnswer: String,
        status: String, isError: Bool, isGenerating: Bool, canRetry: Bool
    ) {
        let followsBottom = transcript.string.isEmpty ||
            transcriptScroll.contentView.bounds.maxY >= transcript.bounds.maxY - 36
        let previousOrigin = transcriptScroll.contentView.bounds.origin
        let previousSelection = transcript.selectedRange()
        let content = NSMutableAttributedString(string: "")
        for message in messages where message.role == "user" || message.role == "assistant" {
            appendEntry(role: message.role, text: message.content, to: content)
        }
        if let pendingUser {
            appendEntry(role: "user", text: pendingUser, to: content)
        }
        if !pendingAnswer.isEmpty {
            appendEntry(role: "assistant", text: pendingAnswer, to: content)
        } else if isGenerating {
            appendEntry(role: "assistant", text: "正在等待回答…", to: content)
        }
        transcript.textStorage?.setAttributedString(content)
        if let textContainer = transcript.textContainer {
            transcript.layoutManager?.ensureLayout(for: textContainer)
        }
        let location = min(previousSelection.location, content.length)
        let length = min(previousSelection.length, content.length - location)
        transcript.setSelectedRange(NSRange(location: location, length: length))
        if followsBottom {
            transcript.scrollRangeToVisible(NSRange(location: content.length, length: 0))
        } else {
            transcriptScroll.contentView.scroll(to: previousOrigin)
            transcriptScroll.reflectScrolledClipView(transcriptScroll.contentView)
        }

        generating = isGenerating
        statusLabel.stringValue = status
        statusLabel.toolTip = status
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        stopButton.isHidden = !isGenerating
        stopButton.isEnabled = isGenerating
        retryButton.isHidden = !canRetry
        retryButton.isEnabled = canRetry && !isGenerating
        hasRecords = !messages.isEmpty || pendingUser != nil
        updateRecordButtons()
        lastAnswer = pendingAnswer.isEmpty
            ? (messages.last(where: { $0.role == "assistant" })?.content ?? "")
            : pendingAnswer
        copyButton.isEnabled = !lastAnswer.isEmpty
        updateSendButton()
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func textDidChange(_ notification: Notification) { updateSendButton() }

    private func appendEntry(role: String, text: String, to content: NSMutableAttributedString) {
        if content.length > 0 { content.append(NSAttributedString(string: "\n\n")) }
        let headingStyle = NSMutableParagraphStyle()
        headingStyle.paragraphSpacing = 5
        content.append(NSAttributedString(
            string: (role == "user" ? "你" : "AI") + "\n",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: headingStyle]
        ))
        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 3
        content.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 14),
                         .foregroundColor: NSColor.labelColor,
                         .paragraphStyle: bodyStyle]
        ))
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "问 AI")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let settingsButton = NSButton(title: "设置", target: self, action: #selector(settingsClicked))
        clearButton.target = self
        clearButton.action = #selector(clearClicked)
        clearButton.toolTip = "清除当前对话记录并停止生成；尚未发送的草稿会保留。"
        clearButton.isEnabled = false
        exportButton.target = self
        exportButton.action = #selector(exportClicked)
        exportButton.toolTip = "将当前对话导出为 Markdown（.md）；生成中的回答只导出已收到的部分。"
        exportButton.isEnabled = false
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.isEnabled = false
        let toolbar = NSStackView(views: [title, spacer, clearButton, exportButton, copyButton, settingsButton])
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.detachesHiddenViews = false

        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.maximumNumberOfLines = 2
        modelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        configureTextView(transcript, editable: false)
        transcript.setAccessibilityLabel("对话记录")
        transcript.textContainerInset = NSSize(width: 10, height: 10)
        transcriptScroll.documentView = transcript
        configureScrollView(transcriptScroll)

        configureTextView(input, editable: true)
        input.delegate = self
        input.textContainerInset = NSSize(width: 8, height: 8)
        input.setAccessibilityLabel("问题输入框")
        input.setAccessibilityHelp("输入问题；Command 加回车发送，回车换行。")
        input.isAutomaticQuoteSubstitutionEnabled = false
        input.isAutomaticDashSubstitutionEnabled = false
        input.isAutomaticTextReplacementEnabled = false
        input.onSubmit = { [weak self] in self?.sendClicked() }
        inputScroll.documentView = input
        configureScrollView(inputScroll)
        inputScroll.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let inputLabel = NSTextField(labelWithString: "提问 / 继续追问")
        inputLabel.font = .systemFont(ofSize: 12, weight: .medium)
        let inputHeaderSpacer = NSView()
        inputHeaderSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        presetButtons = AIPreset.allCases.enumerated().map { index, preset in
            let button = NSButton(title: preset.title, target: self, action: #selector(presetClicked(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 12)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setAccessibilityLabel(preset.title)
            button.toolTip = "点击立即发送此指令。优先使用输入框中的内容，输入框为空时使用本次划词；没有内容时会提示补充。"
            return button
        }
        // Keep all presets visible on their own input-header row, separate from
        // Send/Stop/Retry, without adding height to the minimum-sized window.
        let inputHeader = NSStackView(views: [inputLabel, inputHeaderSpacer] + presetButtons)
        inputHeader.orientation = .horizontal
        inputHeader.alignment = .centerY
        inputHeader.spacing = 8

        let hint = NSTextField(labelWithString: "预设点击即发送 · ⌘↩ 发送")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.toolTip = "点击预设会立即发送指令和待处理内容。自行输入的问题可用 Command 加回车发送，回车换行。"
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.target = self
        sendButton.action = #selector(sendClicked)
        sendButton.isEnabled = false
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        retryButton.isHidden = true
        let footer = NSStackView(views: [hint, footerSpacer, stopButton, retryButton, sendButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 8
        footer.detachesHiddenViews = false
        for button in [settingsButton, clearButton, exportButton, copyButton, sendButton, stopButton, retryButton] {
            button.bezelStyle = .rounded
        }

        let sections: [NSView] = [toolbar, modelLabel, transcriptScroll, statusLabel, inputHeader, inputScroll, footer]
        for view in sections {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
            ])
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            toolbar.heightAnchor.constraint(equalToConstant: 30),
            modelLabel.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 5),
            transcriptScroll.topAnchor.constraint(equalTo: modelLabel.bottomAnchor, constant: 10),
            transcriptScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            statusLabel.topAnchor.constraint(equalTo: transcriptScroll.bottomAnchor, constant: 8),
            inputHeader.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            inputScroll.topAnchor.constraint(equalTo: inputHeader.bottomAnchor, constant: 5),
            inputScroll.heightAnchor.constraint(equalToConstant: 90),
            footer.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 8),
            footer.heightAnchor.constraint(equalToConstant: 30),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
    }

    private func configureTextView(_ view: NSTextView, editable: Bool) {
        view.isEditable = editable
        view.isSelectable = true
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = editable
        view.font = .systemFont(ofSize: 14)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.lineFragmentPadding = 2
        view.textContainer?.containerSize = NSSize(width: 544, height: CGFloat.greatestFiniteMagnitude)
    }

    private func configureScrollView(_ scrollView: NSScrollView) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.borderType = .noBorder
    }

    private func updateSendButton() {
        sendButton.isEnabled = !generating && presetDraft.canSubmit(input.string)
        for button in presetButtons { button.isEnabled = !generating }
    }

    private func updateRecordButtons() {
        clearButton.isEnabled = hasRecords && !exporting
        exportButton.isEnabled = hasRecords && !exporting
    }

    private func fitOnScreen(near point: NSPoint? = nil) {
        guard let window else { return }
        let screen: NSScreen?
        if let point {
            let screens = NSScreen.screens
            let index = ChatWindowPlacement.screenIndex(near: point, frames: screens.map { $0.frame })
            screen = index.map { screens[$0] } ?? NSScreen.main
        } else {
            // Menu reopening and follow-up questions retain the user's position.
            screen = window.screen ?? NSScreen.main
        }
        guard let visibleFrame = screen?.visibleFrame else { return }
        let frame = ChatWindowPlacement.frame(window.frame, in: visibleFrame, near: point)
        window.setFrame(frame, display: true)
    }

    @objc private func sendClicked() {
        let prompt = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !generating, presetDraft.canSubmit(input.string), !input.hasMarkedText() else { return }
        onSend?(prompt)
    }
    @objc private func presetClicked(_ sender: NSButton) {
        let index = sender.tag
        guard !generating, AIPreset.allCases.indices.contains(index), !input.hasMarkedText() else { return }
        let range = NSRange(location: 0, length: input.string.utf16.count)
        var nextState = presetDraft
        let draft = nextState.prepare(AIPreset.allCases[index], currentDraft: input.string)
        guard nextState.canSubmit(draft.text) else {
            statusLabel.stringValue = "请先输入或划选需要处理的文字，再点击预设。"
            statusLabel.toolTip = statusLabel.stringValue
            statusLabel.textColor = .secondaryLabelColor
            window?.makeFirstResponder(input)
            return
        }
        guard input.shouldChangeText(in: range, replacementString: draft.text) else { return }
        presetDraft = nextState
        input.breakUndoCoalescing()
        input.textStorage?.replaceCharacters(in: range, with: draft.text)
        input.didChangeText()
        input.breakUndoCoalescing()
        input.setSelectedRange(draft.selectedRange)
        input.scrollRangeToVisible(draft.selectedRange)
        window?.makeFirstResponder(input)
        updateSendButton()
        // Use the normal submission path once. It synchronously updates the
        // generating state and clears the input only after accepting the request.
        sendClicked()
    }
    @objc private func stopClicked() { onStop?() }
    @objc private func retryClicked() { onRetry?() }
    @objc private func clearClicked() {
        setSelectionContext("")
        onClear?()
    }
    @objc private func exportClicked() {
        guard hasRecords, !exporting else { return }
        onExport?()
    }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func copyClicked() {
        guard !lastAnswer.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastAnswer, forType: .string)
    }
}
