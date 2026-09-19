import AppKit

/// Clip both the behind-window material and its foreground content. Clipping
/// only the backing layer can leave the backdrop visible outside the corners.
@MainActor
private final class AssistantSurfaceView: NSVisualEffectView {
    private var maskedSize: NSSize?
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        updateCornerMask()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        maskedSize = nil
        updateCornerMask()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        maskedSize = nil
        updateCornerMask()
    }

    private func updateCornerMask() {
        let size = bounds.size
        guard size.width > 0, size.height > 0, maskedSize != size else { return }
        // Record first: assigning maskImage can cause another layout pass.
        maskedSize = size
        let radius = min(12, min(size.width, size.height) / 2)
        layer?.cornerRadius = radius
        // A drawing-backed image uses point dimensions and renders at the
        // destination scale, including Retina and mixed-scale displays.
        maskImage = NSImage(size: size, flipped: false) { rect in
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        window?.invalidateShadow()
    }
}

private final class SelectionAssistantPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            onEscape?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class DraggablePanelHeader: NSStackView {
    var onDrag: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
}

private final class DraggablePanelTitle: NSTextField {
    var onDrag: ((NSEvent) -> Void)?
    override func mouseDown(with event: NSEvent) { onDrag?(event) }
}

@MainActor
final class AssistantPanelController: NSObject {
    var onAction: ((CompletionMode) -> Void)?
    var onClose: (() -> Void)?
    var onStop: (() -> Void)?
    var onRetry: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onTargetLanguageChange: ((TranslationLanguage) -> Void)?
    var englishAccentProvider: (() -> EnglishAccent)?
    var onPronunciationStart: (() -> Void)?

    private let panel: SelectionAssistantPanel
    private let actionsView = AssistantSurfaceView(frame: .zero)
    private let resultView = AssistantSurfaceView(frame: .zero)
    private let titleLabel = DraggablePanelTitle(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let modelInfoLabel = NSTextField(wrappingLabelWithString: "")
    private let translateButton = NSButton(title: "翻译", target: nil, action: nil)
    private let languageRow = NSStackView()
    private let targetLanguagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let dictionaryHeader = NSView()
    private let dictionaryWordLabel = NSTextField(wrappingLabelWithString: "")
    private let pronunciationRow = NSView()
    private let pronunciationLabel = NSTextField(wrappingLabelWithString: "")
    private let pronunciationButton = NSButton(title: "", target: nil, action: nil)
    private let speech = EnglishSpeechController()
    private let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let copyButton = NSButton(title: "复制", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let pinButton = NSButton(title: "", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "", target: nil, action: nil)
    private var anchor = NSPoint.zero
    private var targetLanguage = TranslationLanguage.simplifiedChinese
    private var displayedMode: CompletionMode = .translate
    private var pendingText = ""
    private var layoutTask: Task<Void, Never>?
    private var statusHeightConstraint: NSLayoutConstraint!
    private var modelInfoHeightConstraint: NSLayoutConstraint!
    private var dictionaryHeaderHeightConstraint: NSLayoutConstraint!
    private var dictionaryWordHeightConstraint: NSLayoutConstraint!
    private var pronunciationWidthConstraint: NSLayoutConstraint!
    private var pronunciationHeightConstraint: NSLayoutConstraint!
    private var pronunciationTopConstraint: NSLayoutConstraint!
    private var pronunciationBaselineConstraint: NSLayoutConstraint!
    private var pronunciationRowHeightConstraint: NSLayoutConstraint!
    private var dictionaryWord: String?
    private var dictionaryCopyPrefix = ""
    private var displayingDictionary = false
    private var translationBodyFontSize: CGFloat?
    private var isDraggingResult = false
    private(set) var isPinned = false

    /// Keep one growth direction for the whole result, including retries/language
    /// changes. Once it reaches a screen edge, clamp continuously instead of flipping.
    private struct ResultPlacement {
        let visibleFrame: NSRect
        let width: CGFloat
        let x: CGFloat
        let growsUp: Bool
        let fixedEdge: CGFloat
        let maximumHeight: CGFloat
    }
    private var resultPlacement: ResultPlacement?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = SelectionAssistantPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        super.init()
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.onEscape = { [weak self] in self?.closeClicked() }
        buildActions()
        buildResult()
    }

    func owns(_ window: NSWindow?) -> Bool { window === panel }

    func showActions(near point: NSPoint) {
        setFavoriteState(available: false, isFavorite: false)
        resetDictionaryHeader()
        cancelScheduledLayout()
        pendingText = ""
        setPinned(false)
        resultPlacement = nil
        anchor = point
        panel.contentView = actionsView
        place(size: NSSize(width: 240, height: 48))
        actionsView.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
    }

    func showResult(mode: CompletionMode) {
        setFavoriteState(available: false, isFavorite: false)
        resetDictionaryHeader()
        cancelScheduledLayout()
        pendingText = ""
        displayingDictionary = false
        if mode != .translate { setPinned(false) }
        if panel.contentView !== resultView || !panel.isVisible {
            resultPlacement = makeResultPlacement()
        }
        displayedMode = mode
        titleLabel.stringValue = mode == .translate ? targetLanguage.actionTitle : mode.title
        languageRow.isHidden = mode != .translate
        replaceBody(with: NSAttributedString(string: "", attributes: bodyAttributes()))
        modelInfoLabel.stringValue = ""
        statusLabel.stringValue = mode == .translate ? "正在处理…" : "正在生成…"
        statusLabel.textColor = .secondaryLabelColor
        copyButton.isEnabled = false
        stopButton.isHidden = false
        retryButton.isHidden = true
        pinButton.isHidden = mode != .translate
        favoriteButton.isHidden = mode != .translate
        panel.contentView = resultView
        scrollView.contentView.scroll(to: .zero)
        updateResultLayout()
        panel.orderFrontRegardless()
    }

    func setTargetLanguage(_ language: TranslationLanguage) {
        targetLanguage = language
        targetLanguagePopup.selectItem(withTitle: language.title)
        translateButton.title = language.actionTitle
        translateButton.toolTip = "自动识别源语言，将所选文字翻译为\(language.title)"
        if displayedMode == .translate { titleLabel.stringValue = language.actionTitle }
    }

    func showUnneededTranslation(original: String, language: TranslationLanguage) {
        resetDictionaryHeader()
        cancelScheduledLayout()
        pendingText = ""
        displayingDictionary = false
        replaceBody(with: NSAttributedString(string: original, attributes: bodyAttributes()))
        statusLabel.stringValue = "所选文字已是\(language.title)，无需翻译。"
        statusLabel.textColor = .secondaryLabelColor
        modelInfoLabel.stringValue = ""
        modelInfoLabel.toolTip = nil
        stopButton.isHidden = true
        retryButton.isHidden = true
        updateResultLayout()
    }

    func showDictionaryLoading(word: String) {
        resetDictionaryHeader()
        cancelScheduledLayout()
        pendingText = ""
        displayingDictionary = true
        replaceBody(with: NSAttributedString(
            string: word,
            attributes: bodyAttributes(size: 24, weight: .semibold, spacingAfter: 8)
        ))
        statusLabel.stringValue = "正在查词…"
        statusLabel.textColor = .secondaryLabelColor
        scrollView.contentView.scroll(to: .zero)
        updateResultLayout()
    }

    /// Model output supplies data only. Fonts, section order and missing-pronunciation
    /// handling are local UI choices, so changing the target cannot change the layout.
    func showDictionary(_ entry: DictionaryEntry, word: String, target: TranslationLanguage) {
        stopPronunciation()
        cancelScheduledLayout()
        pendingText = ""
        displayingDictionary = true
        dictionaryWord = word
        dictionaryWordLabel.stringValue = word
        pronunciationLabel.stringValue = "音标  " + (entry.pronunciation ?? "暂无可靠音标")
        dictionaryCopyPrefix = word + "\n" + pronunciationLabel.stringValue + "\n\n"
        pronunciationButton.isHidden = entry.sourceLanguage != "en" || TranslationRequest.sourceWord(text: word) != word
        pronunciationButton.isEnabled = !pronunciationButton.isHidden
        dictionaryHeader.isHidden = false
        let body = NSMutableAttributedString(string: "")
        let targetDirection: NSWritingDirection = target == .arabic ? .rightToLeft : .natural
        func paragraph(_ value: String, size: CGFloat = 14, weight: NSFont.Weight = .regular,
                       direction: NSWritingDirection = .natural,
                       color: NSColor = .labelColor, spacing: CGFloat = 5) {
            body.append(NSAttributedString(string: value + "\n", attributes: bodyAttributes(
                size: size, weight: weight, direction: direction,
                color: color, spacingAfter: spacing
            )))
        }
        func heading(_ value: String) {
            paragraph(value, size: 13, weight: .semibold, direction: .leftToRight,
                      color: .secondaryLabelColor, spacing: 6)
        }
        heading("词性与释义")
        for sense in entry.senses {
            paragraph(sense.partOfSpeech, weight: .medium, direction: targetDirection, spacing: 2)
            paragraph(sense.meaning, direction: targetDirection, spacing: 10)
        }
        heading("常见搭配")
        for collocation in entry.collocations {
            paragraph(collocation.text, weight: .medium, spacing: 2)
            paragraph(collocation.translation, direction: targetDirection, spacing: 10)
        }
        heading("例句")
        for example in entry.examples {
            paragraph(example.text, spacing: 2)
            paragraph(example.translation, direction: targetDirection, spacing: 10)
        }
        replaceBody(with: body)
        textView.setAccessibilityLabel("词典解释")
        scrollView.contentView.scroll(to: .zero)
        updateResultLayout()
    }

    /// Shows metadata returned by the API, never a model's claim about its identity.
    func setModelInfo(requested: String, returned: String?, endpointHost: String) {
        let actual = returned?.trimmingCharacters(in: .whitespacesAndNewlines)
        let returnedName = actual.flatMap { $0.isEmpty ? nil : $0 } ?? "接口未返回"
        modelInfoLabel.stringValue = "请求：\(requested) · 返回：\(returnedName)\n接口：\(endpointHost)"
        modelInfoLabel.toolTip = modelInfoLabel.stringValue
        scheduleResultLayout()
    }

    func append(_ text: String) {
        // Buffer tokens too: NSTextView can otherwise re-layout after every append.
        pendingText += text
        scheduleResultLayout()
    }

    func showError(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
        stopButton.isHidden = true
        retryButton.isHidden = false
        updateResultLayout()
    }

    func finish(note: String? = nil) {
        statusLabel.stringValue = note ?? "已完成"
        statusLabel.textColor = .secondaryLabelColor
        stopButton.isHidden = true
        retryButton.isHidden = false
        updateResultLayout()
    }

    func stop() {
        statusLabel.stringValue = "已停止"
        statusLabel.textColor = .secondaryLabelColor
        stopButton.isHidden = true
        retryButton.isHidden = false
        updateResultLayout()
    }

    func hide() {
        resetDictionaryHeader()
        cancelScheduledLayout()
        pendingText = ""
        setPinned(false)
        resultPlacement = nil
        panel.orderOut(nil)
    }

    func stopPronunciation() {
        speech.stop()
    }

    private func refreshPronunciationSource() {
        pronunciationButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "朗读英文原词")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        pronunciationButton.toolTip = "使用 macOS 系统语音朗读英文原词；可在设置中选择英音或美音"
        pronunciationButton.setAccessibilityLabel("使用系统语音朗读英文原词")
    }

    func setFavoriteState(available: Bool, isFavorite: Bool) {
        let label = isFavorite ? "取消收藏" : "收藏翻译"
        favoriteButton.isEnabled = available
        favoriteButton.image = NSImage(systemSymbolName: isFavorite ? "star.fill" : "star",
                                       accessibilityDescription: label)
        favoriteButton.contentTintColor = isFavorite ? .systemYellow : .labelColor
        favoriteButton.toolTip = available ? label : "翻译完成后可收藏"
        favoriteButton.setAccessibilityLabel(label)
        favoriteButton.state = isFavorite ? .on : .off
    }

    private func resetDictionaryHeader() {
        stopPronunciation()
        dictionaryWord = nil
        dictionaryCopyPrefix = ""
        dictionaryHeader.isHidden = true
        pronunciationButton.isEnabled = false
        dictionaryHeaderHeightConstraint?.constant = 0
    }

    private func cancelScheduledLayout() {
        layoutTask?.cancel()
        layoutTask = nil
    }

    private func scheduleResultLayout() {
        guard panel.contentView === resultView, layoutTask == nil else { return }
        layoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 60_000_000) }
            catch { return }
            guard !Task.isCancelled, let self else { return }
            self.layoutTask = nil
            self.updateResultLayout()
        }
    }

    private func makeResultPlacement() -> ResultPlacement {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800))
            .insetBy(dx: 8, dy: 8)
        let width = min(480, visible.width)
        let belowEdge = min(max(anchor.y - 12, visible.minY), visible.maxY)
        let aboveEdge = min(max(anchor.y + 16, visible.minY), visible.maxY)
        let belowSpace = belowEdge - visible.minY
        let aboveSpace = visible.maxY - aboveEdge
        let growsUp = aboveSpace > belowSpace
        return ResultPlacement(
            visibleFrame: visible,
            width: width,
            x: min(max(anchor.x + 8, visible.minX), visible.maxX - width),
            growsUp: growsUp,
            fixedEdge: growsUp ? aboveEdge : belowEdge,
            maximumHeight: min(680, visible.height * 0.8)
        )
    }

    private func wrappedLabelHeight(_ label: NSTextField, width: CGFloat) -> CGFloat {
        guard !label.stringValue.isEmpty else { return 0 }
        label.preferredMaxLayoutWidth = width
        let bounds = NSRect(x: 0, y: 0, width: width, height: CGFloat.greatestFiniteMagnitude)
        return ceil(label.cell?.cellSize(forBounds: bounds).height ?? label.intrinsicContentSize.height)
    }

    private func updateResultLayout() {
        cancelScheduledLayout()
        guard panel.contentView === resultView, !isDraggingResult else { return }
        if resultPlacement == nil { resultPlacement = makeResultPlacement() }
        guard let placement = resultPlacement,
              let container = textView.textContainer,
              let manager = textView.layoutManager else { return }

        // Read the user's scroll position before adding or measuring more text.
        let previousOrigin = scrollView.contentView.bounds.origin
        let followsBottom = !displayingDictionary && (textView.string.isEmpty ||
            scrollView.documentVisibleRect.maxY >= textView.bounds.maxY - 2)
        if !pendingText.isEmpty {
            let fontSize: CGFloat = displayedMode == .translate && !displayingDictionary
                ? translationBodyFontSize ?? 20 : 14
            textView.textStorage?.append(NSAttributedString(
                string: pendingText, attributes: bodyAttributes(size: fontSize)
            ))
            pendingText = ""
        }

        let bodyWidth = max(1, placement.width - 32)
        // Reserve the native hit area even when a short result hides the thumb.
        // This keeps wrapping stable as the scrollbar appears while streaming.
        let scrollerWidth = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let textWidth = max(1, bodyWidth - scrollerWidth - 4)
        textView.setFrameSize(NSSize(width: textWidth, height: max(1, textView.frame.height)))
        container.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        applyAdaptiveTranslationFont(width: textWidth)
        manager.ensureLayout(for: container)
        // Include the extra line fragment so a trailing newline is not clipped.
        let laidOutHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let textHeight = ceil(laidOutHeight + textView.textContainerInset.height * 2)
        let statusHeight = wrappedLabelHeight(statusLabel, width: bodyWidth)
        let modelHeight = wrappedLabelHeight(modelInfoLabel, width: bodyWidth)
        statusHeightConstraint.constant = statusHeight
        modelInfoHeightConstraint.constant = modelHeight
        var dictionaryHeaderHeight: CGFloat = 0
        if !dictionaryHeader.isHidden {
            let wordHeight = wrappedLabelHeight(dictionaryWordLabel, width: bodyWidth)
            let speakerWidth: CGFloat = pronunciationButton.isHidden ? 0 : 30
            let availablePronunciationWidth = max(1, bodyWidth - speakerWidth)
            let font = pronunciationLabel.font ?? .systemFont(ofSize: 13)
            // Measure with the same cell that draws the text, including its
            // insets and fallback fonts, instead of a separate NSString metric.
            let measuringCell = pronunciationLabel.cell?.copy() as? NSTextFieldCell
            measuringCell?.wraps = false
            measuringCell?.usesSingleLineMode = true
            measuringCell?.lineBreakMode = .byClipping
            let naturalPronunciationWidth = ceil(measuringCell?.cellSize.width
                ?? pronunciationLabel.intrinsicContentSize.width) + 1
            let pronunciationWidth = min(availablePronunciationWidth, naturalPronunciationWidth)
            let pronunciationHeight = wrappedLabelHeight(pronunciationLabel, width: pronunciationWidth)
            dictionaryWordHeightConstraint.constant = wordHeight
            pronunciationWidthConstraint.constant = pronunciationWidth
            pronunciationHeightConstraint.constant = pronunciationHeight
            pronunciationLabel.setFrameSize(NSSize(width: pronunciationWidth, height: pronunciationHeight))
            // Align the icon with the first line's visible text, not the center
            // of the cell or a multi-line text block. Keep its full 24pt hit area
            // inside the row using the actual AppKit baseline offset.
            let glyphCenterFromTop = pronunciationLabel.firstBaselineOffsetFromTop - font.capHeight / 2
            let topInset = pronunciationButton.isHidden ? 0 : max(0, 12 - glyphCenterFromTop)
            pronunciationTopConstraint.constant = topInset
            pronunciationBaselineConstraint.constant = -font.capHeight / 2
            let pronunciationRowHeight = ceil(max(topInset + pronunciationHeight,
                pronunciationButton.isHidden ? 0 : topInset + glyphCenterFromTop + 12))
            pronunciationRowHeightConstraint.constant = pronunciationRowHeight
            dictionaryHeaderHeight = wordHeight + 6 + pronunciationRowHeight + 8
        }
        dictionaryHeaderHeightConstraint.constant = dictionaryHeaderHeight

        // These fixed heights/spacings match buildResult; the body is the only
        // flexible area. Short responses shrink again after retrying a long one.
        let chromeHeight: CGFloat = 12 + 26 + 6 + 26 + 4 + 8 + 6 + 12 + statusHeight + modelHeight + dictionaryHeaderHeight
        let height = min(chromeHeight + max(48, textHeight), placement.maximumHeight)
        let proposedY = placement.growsUp ? placement.fixedEdge : placement.fixedEdge - height
        let y = min(max(proposedY, placement.visibleFrame.minY), placement.visibleFrame.maxY - height)
        panel.setFrame(NSRect(x: placement.x, y: y, width: placement.width, height: height), display: true)
        resultView.layoutSubtreeIfNeeded()
        textView.setFrameSize(NSSize(width: max(1, scrollView.contentSize.width),
                                    height: max(textHeight, scrollView.contentSize.height)))
        copyButton.isEnabled = !textView.string.isEmpty

        let scrollY = followsBottom
            ? max(0, textView.bounds.height - scrollView.contentView.bounds.height)
            : min(previousOrigin.y, max(0, textView.bounds.height - scrollView.contentView.bounds.height))
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func applyAdaptiveTranslationFont(width: CGFloat) {
        guard displayedMode == .translate, !displayingDictionary,
              let storage = textView.textStorage else { return }

        // Measure at a fixed reference size: scripts with wider glyphs and explicit
        // line breaks count by the space they occupy, not their character count.
        // Keeping this independent of the displayed font avoids a layout feedback loop.
        let referenceHeight = (storage.string as NSString).boundingRect(
            with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: bodyAttributes()
        ).height
        let preferredSize: CGFloat
        switch referenceHeight {
        case ...100: preferredSize = 20
        case ...200: preferredSize = 18
        case ...320: preferredSize = 16
        default: preferredSize = 14
        }

        // A growing response can shrink through only three steps. Replacing the
        // body (including retry and target changes) resets this limit for new text.
        let fontSize = min(translationBodyFontSize ?? 20, preferredSize)
        guard translationBodyFontSize != fontSize else { return }
        translationBodyFontSize = fontSize
        let font = NSFont.systemFont(ofSize: fontSize)
        if storage.length > 0 {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
        textView.typingAttributes = bodyAttributes(size: fontSize)
    }

    private func bodyAttributes(size: CGFloat = 14, weight: NSFont.Weight = .regular,
                                direction: NSWritingDirection = .natural,
                                color: NSColor = .labelColor,
                                spacingAfter: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = direction
        paragraph.alignment = .natural
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacing = spacingAfter
        return [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
    }

    private func replaceBody(with text: NSAttributedString) {
        translationBodyFontSize = nil
        textView.textStorage?.setAttributedString(text)
        // NSTextView otherwise inherits the preceding dictionary heading's style
        // when the next ordinary translation starts with an empty string.
        textView.typingAttributes = bodyAttributes()
        textView.setAccessibilityLabel(displayingDictionary ? "词典解释" : "翻译结果")
    }

    private func setPinned(_ pinned: Bool) {
        isPinned = pinned
        let label = pinned ? "取消固定窗口" : "固定窗口"
        pinButton.image = NSImage(systemSymbolName: pinned ? "pin.fill" : "pin",
                                  accessibilityDescription: label)
        pinButton.contentTintColor = pinned ? .controlAccentColor : .labelColor
        pinButton.toolTip = pinned
            ? "已固定：拖动标题栏移动；取消固定后可查看新划词；点 × 或按 Esc 关闭"
            : "固定窗口：点击其他应用时保留"
        pinButton.setAccessibilityLabel(label)
        pinButton.state = pinned ? .on : .off
    }

    private func dragResult(with event: NSEvent) {
        guard isPinned, panel.contentView === resultView else { return }
        isDraggingResult = true
        panel.performDrag(with: event)
        isDraggingResult = false
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? panel.screen ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800))
            .insetBy(dx: 8, dy: 8)
        let width = min(480, visible.width)
        resultPlacement = ResultPlacement(
            visibleFrame: visible, width: width,
            x: min(max(frame.minX, visible.minX), visible.maxX - width),
            growsUp: false, fixedEdge: min(max(frame.maxY, visible.minY), visible.maxY),
            maximumHeight: min(680, visible.height * 0.8)
        )
        updateResultLayout()
    }

    private func buildActions() {
        translateButton.target = self
        translateButton.action = #selector(translateClicked)
        let ask = NSButton(title: "问 AI", target: self, action: #selector(askClicked))
        translateButton.toolTip = "自动识别源语言，将所选文字翻译为简体中文"
        ask.toolTip = "直接发送所选文字给 AI，可在对话窗口中继续追问"
        for button in [translateButton, ask] {
            button.bezelStyle = .rounded
            button.font = .systemFont(ofSize: 13, weight: .medium)
        }
        let row = NSStackView(views: [translateButton, ask])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        actionsView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: actionsView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: actionsView.trailingAnchor, constant: -10),
            row.centerYAnchor.constraint(equalTo: actionsView.centerYAnchor)
        ])
    }

    private func buildResult() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        retryButton.target = self
        retryButton.action = #selector(retryClicked)
        pinButton.target = self
        pinButton.action = #selector(pinClicked)
        pinButton.isBordered = false
        pinButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        pinButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        setPinned(false)
        favoriteButton.target = self
        favoriteButton.action = #selector(favoriteClicked)
        favoriteButton.isBordered = false
        favoriteButton.widthAnchor.constraint(equalToConstant: 24).isActive = true
        favoriteButton.heightAnchor.constraint(equalToConstant: 24).isActive = true
        setFavoriteState(available: false, isFavorite: false)
        let settings = iconButton("gearshape", label: "设置", action: #selector(settingsClicked))
        let close = iconButton("xmark", label: "关闭", action: #selector(closeClicked))
        for button in [copyButton, stopButton, retryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
        }
        let toolbar = DraggablePanelHeader(views: [titleLabel, copyButton, stopButton, retryButton, favoriteButton, pinButton, settings, close])
        toolbar.onDrag = { [weak self] event in self?.dragResult(with: event) }
        titleLabel.onDrag = { [weak self] event in self?.dragResult(with: event) }
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        toolbar.detachesHiddenViews = true

        let sourceLanguageLabel = NSTextField(labelWithString: "源语言：自动识别 →")
        sourceLanguageLabel.font = .systemFont(ofSize: 12)
        sourceLanguageLabel.textColor = .secondaryLabelColor
        sourceLanguageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        targetLanguagePopup.addItems(withTitles: TranslationLanguage.allCases.map(\.title))
        targetLanguagePopup.target = self
        targetLanguagePopup.action = #selector(targetLanguageChanged)
        targetLanguagePopup.controlSize = .small
        targetLanguagePopup.font = .systemFont(ofSize: 12)
        targetLanguagePopup.setAccessibilityLabel("翻译目标语言")
        targetLanguagePopup.toolTip = "选择目标语言后会重新翻译当前选中文字"
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 8
        languageRow.addArrangedSubview(sourceLanguageLabel)
        languageRow.addArrangedSubview(targetLanguagePopup)
        languageRow.addArrangedSubview(NSView())

        dictionaryHeader.isHidden = true
        dictionaryWordLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        dictionaryWordLabel.maximumNumberOfLines = 0
        dictionaryWordLabel.isSelectable = true
        dictionaryWordLabel.baseWritingDirection = .leftToRight
        dictionaryWordLabel.setAccessibilityLabel("查询原词")
        pronunciationLabel.font = .systemFont(ofSize: 13)
        pronunciationLabel.textColor = .secondaryLabelColor
        pronunciationLabel.maximumNumberOfLines = 0
        pronunciationLabel.isSelectable = true
        pronunciationLabel.baseWritingDirection = .leftToRight
        pronunciationLabel.setAccessibilityLabel("原词音标")
        pronunciationButton.target = self
        pronunciationButton.action = #selector(pronunciationClicked)
        pronunciationButton.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: "朗读英文原词")
        pronunciationButton.imagePosition = .imageOnly
        pronunciationButton.isBordered = false
        refreshPronunciationSource()
        pronunciationButton.setAccessibilityLabel("朗读英文原词")
        pronunciationButton.isEnabled = false
        let dictionaryHeaderViews: [NSView] = [dictionaryWordLabel, pronunciationRow]
        for view in dictionaryHeaderViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            dictionaryHeader.addSubview(view)
        }
        for view in [pronunciationLabel, pronunciationButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            pronunciationRow.addSubview(view)
        }
        dictionaryWordHeightConstraint = dictionaryWordLabel.heightAnchor.constraint(equalToConstant: 30)
        pronunciationWidthConstraint = pronunciationLabel.widthAnchor.constraint(equalToConstant: 100)
        pronunciationHeightConstraint = pronunciationLabel.heightAnchor.constraint(equalToConstant: 24)
        pronunciationTopConstraint = pronunciationLabel.topAnchor.constraint(equalTo: pronunciationRow.topAnchor)
        pronunciationBaselineConstraint = pronunciationButton.centerYAnchor.constraint(
            equalTo: pronunciationLabel.firstBaselineAnchor,
            constant: -(pronunciationLabel.font?.capHeight ?? 9) / 2)
        pronunciationRowHeightConstraint = pronunciationRow.heightAnchor.constraint(equalToConstant: 24)
        NSLayoutConstraint.activate([
            dictionaryWordLabel.topAnchor.constraint(equalTo: dictionaryHeader.topAnchor),
            dictionaryWordLabel.leadingAnchor.constraint(equalTo: dictionaryHeader.leadingAnchor),
            dictionaryWordLabel.trailingAnchor.constraint(equalTo: dictionaryHeader.trailingAnchor),
            dictionaryWordHeightConstraint,
            pronunciationRow.topAnchor.constraint(equalTo: dictionaryWordLabel.bottomAnchor, constant: 6),
            pronunciationRow.leadingAnchor.constraint(equalTo: dictionaryHeader.leadingAnchor),
            pronunciationRow.trailingAnchor.constraint(equalTo: dictionaryHeader.trailingAnchor),
            pronunciationRowHeightConstraint,
            pronunciationLabel.leadingAnchor.constraint(equalTo: pronunciationRow.leadingAnchor),
            pronunciationTopConstraint,
            pronunciationWidthConstraint,
            pronunciationHeightConstraint,
            pronunciationButton.leadingAnchor.constraint(equalTo: pronunciationLabel.trailingAnchor, constant: 6),
            pronunciationBaselineConstraint,
            pronunciationButton.widthAnchor.constraint(equalToConstant: 24),
            pronunciationButton.heightAnchor.constraint(equalToConstant: 24)
        ])

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 0, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.frame = NSRect(x: 0, y: 0, width: 428, height: 230)
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // updateResultLayout supplies a stable width that reserves the scroller.
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: 428, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("模型回答")
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .legacy
        scrollView.verticalScroller = SubtleScroller(frame: .zero)
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.documentView = textView

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.required, for: .vertical)
        modelInfoLabel.font = .systemFont(ofSize: 10)
        modelInfoLabel.textColor = .tertiaryLabelColor
        modelInfoLabel.maximumNumberOfLines = 0
        modelInfoLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        modelInfoLabel.setContentHuggingPriority(.required, for: .vertical)
        let contentViews: [NSView] = [toolbar, languageRow, dictionaryHeader, scrollView, statusLabel, modelInfoLabel]
        for view in contentViews {
            view.translatesAutoresizingMaskIntoConstraints = false
            resultView.addSubview(view)
        }
        statusHeightConstraint = statusLabel.heightAnchor.constraint(equalToConstant: 14)
        modelInfoHeightConstraint = modelInfoLabel.heightAnchor.constraint(equalToConstant: 0)
        dictionaryHeaderHeightConstraint = dictionaryHeader.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            statusHeightConstraint,
            modelInfoHeightConstraint,
            dictionaryHeaderHeightConstraint,
            toolbar.topAnchor.constraint(equalTo: resultView.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            toolbar.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -12),
            toolbar.heightAnchor.constraint(equalToConstant: 26),
            languageRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            languageRow.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            languageRow.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -16),
            languageRow.heightAnchor.constraint(equalToConstant: 26),
            targetLanguagePopup.widthAnchor.constraint(equalToConstant: 145),
            dictionaryHeader.topAnchor.constraint(equalTo: languageRow.bottomAnchor, constant: 4),
            dictionaryHeader.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            dictionaryHeader.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -16),
            scrollView.topAnchor.constraint(equalTo: dictionaryHeader.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),
            statusLabel.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -16),
            statusLabel.bottomAnchor.constraint(equalTo: modelInfoLabel.topAnchor, constant: -6),
            modelInfoLabel.leadingAnchor.constraint(equalTo: resultView.leadingAnchor, constant: 16),
            modelInfoLabel.trailingAnchor.constraint(equalTo: resultView.trailingAnchor, constant: -16),
            modelInfoLabel.bottomAnchor.constraint(equalTo: resultView.bottomAnchor, constant: -12)
        ])
    }

    private func iconButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(title: "", target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.isBordered = false
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        button.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func place(size requested: NSSize) {
        let screen = NSScreen.screens.first(where: { $0.frame.contains(anchor) }) ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let size = NSSize(width: min(requested.width, visible.width - 16), height: min(requested.height, visible.height - 16))
        var y = anchor.y - size.height - 12
        if y < visible.minY + 8 { y = anchor.y + 16 }
        let origin = NSPoint(
            x: min(max(anchor.x + 8, visible.minX + 8), visible.maxX - size.width - 8),
            y: min(max(y, visible.minY + 8), visible.maxY - size.height - 8)
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    @objc private func translateClicked() { onAction?(.translate) }
    @objc private func askClicked() { onAction?(.ask) }
    @objc private func targetLanguageChanged() {
        let index = targetLanguagePopup.indexOfSelectedItem
        guard TranslationLanguage.allCases.indices.contains(index) else { return }
        let language = TranslationLanguage.allCases[index]
        guard language != targetLanguage else { return }
        stopPronunciation()
        setTargetLanguage(language)
        onTargetLanguageChange?(language)
    }
    @objc private func copyClicked() {
        updateResultLayout()
        guard !textView.string.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(dictionaryCopyPrefix + textView.string, forType: .string)
        statusLabel.stringValue = "已复制"
        statusLabel.textColor = .secondaryLabelColor
        updateResultLayout()
    }
    @objc private func pinClicked() {
        guard panel.contentView === resultView, displayedMode == .translate else { return }
        setPinned(!isPinned)
    }
    @objc private func stopClicked() { onStop?() }
    @objc private func favoriteClicked() { onToggleFavorite?() }
    @objc private func retryClicked() {
        stopPronunciation()
        onRetry?()
    }
    @objc private func pronunciationClicked() {
        guard !dictionaryHeader.isHidden, pronunciationButton.isEnabled,
              let word = dictionaryWord, !word.isEmpty else { return }
        stopPronunciation()
        onPronunciationStart?()
        do {
            try speech.speak(word: word, accent: englishAccentProvider?() ?? .american)
            statusLabel.stringValue = "系统语音 · 朗读英文原词"
            statusLabel.textColor = .secondaryLabelColor
        } catch {
            // Keep the dictionary visible when only pronunciation fails.
            statusLabel.stringValue = error.localizedDescription
            statusLabel.textColor = .systemRed
        }
        updateResultLayout()
    }
    @objc private func settingsClicked() { onOpenSettings?() }
    @objc private func closeClicked() {
        hide()
        onClose?()
    }
}
