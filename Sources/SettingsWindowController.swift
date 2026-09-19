import AppKit

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let store: SettingsStore
    private let permissionStatus: () -> Bool
    private let onRequestPermission: () -> Void
    private let onRefreshPermission: () -> Void
    private let onRepairPermission: () -> Void
    var onClearTranslationCache: (() -> Void)?
    var onOpenTranslationHistory: (() -> Void)?
    var onPreviewSpeech: (() -> Void)?
    private let profilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let profileNameField = NSTextField()
    private let deleteProfileButton = NSButton(title: "删除", target: nil, action: nil)
    private let translationProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let chatProfilePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let baseURLField = NSTextField()
    private let modelField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let enabledButton = NSButton(checkboxWithTitle: "启用划词助手", target: nil, action: nil)
    private let showMenuBarIconButton = NSButton(checkboxWithTitle: "显示菜单栏图标", target: nil, action: nil)
    private let menuBarVisibilityHint = NSTextField(wrappingLabelWithString: "")
    private let popupAfterCopyButton = NSButton(checkboxWithTitle: "复制后显示划词选项（兼容模式）", target: nil, action: nil)
    private let englishAccentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let speechStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let speechPreviewButton = NSButton(title: "试听 apple", target: nil, action: nil)
    private let speechStopButton = NSButton(title: "停止试听", target: nil, action: nil)
    private var speechGroup: NSStackView?
    private let speechPreviewController = EnglishSpeechController()
    private let permissionLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "打开系统设置", target: nil, action: nil)
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "保存当前配置", target: nil, action: nil)
    private let testButton = NSButton(title: "保存并测试连接", target: nil, action: nil)
    private let balanceProviderLabel = NSTextField(labelWithString: "")
    private let balanceAmountLabel = NSTextField(wrappingLabelWithString: "")
    private let balanceStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let balanceUpdatedLabel = NSTextField(wrappingLabelWithString: "")
    private let balanceRefreshButton = NSButton(title: "刷新余额", target: nil, action: nil)
    private let balanceAccountButton = NSButton(title: "账户后台", target: nil, action: nil)
    private let cacheEnabledButton = NSButton(checkboxWithTitle: "启用翻译缓存", target: nil, action: nil)
    private let cacheEntriesField = NSTextField()
    private let cacheMegabytesField = NSTextField()
    private let historyEnabledButton = NSButton(checkboxWithTitle: "保存翻译历史", target: nil, action: nil)
    private let cacheStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let formScrollView = NSScrollView()
    private let formDocument = SettingsDocumentView()
    private var formStack: NSStackView?
    private var testTask: Task<Void, Never>?
    private var testGeneration = 0
    private var balanceState = BalanceDisplayState()
    private var balanceTask: Task<Void, Never>?
    // A snapshot of saved settings only. Editing any API field discards it.
    private var savedBalanceConfiguration: APIConfiguration?
    private var editingProfileID: String?
    private var profileHasChanges = false

    init(store: SettingsStore, permissionStatus: @escaping () -> Bool,
         onRequestPermission: @escaping () -> Void,
         onRefreshPermission: @escaping () -> Void,
         onRepairPermission: @escaping () -> Void) {
        self.store = store
        self.permissionStatus = permissionStatus
        self.onRequestPermission = onRequestPermission
        self.onRefreshPermission = onRefreshPermission
        self.onRepairPermission = onRepairPermission
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 530, height: 630),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "划词助手 · 设置"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        let isNewPresentation = window?.isVisible != true
        if isNewPresentation { loadSettings() }
        refreshPreferenceControls()
        refreshPermission()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if isNewPresentation, savedBalanceConfiguration != nil {
            refreshBalance()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshPreferenceControls()
        refreshPermission()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopSpeechPreview()
        guard commitTranslationPreferencesBeforeClosing() else { return false }
        guard confirmLeavingProfile() else { return false }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        stopSpeechPreview()
        cancelTest()
        cancelBalance()
        balanceState.reset(provider: .unconfigured, requiresSave: false)
        savedBalanceConfiguration = nil
        apiKeyField.stringValue = ""
        profileHasChanges = false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === cacheEntriesField || field === cacheMegabytesField {
            // Wait until editing ends: saving an intermediate "2" while typing
            // "200" would immediately discard otherwise useful cached results.
            return
        }
        guard [profileNameField, baseURLField, apiKeyField, modelField].contains(where: { $0 === field }) else { return }
        profileHasChanges = true
        cancelTest()
        cancelBalance()
        savedBalanceConfiguration = nil
        balanceState.reset(provider: .detect(baseURL: baseURLField.stringValue), requiresSave: true)
        renderBalance()
        setStatus("")
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              field === cacheEntriesField || field === cacheMegabytesField else { return }
        saveTranslationPreferences()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        formScrollView.frame = content.bounds
        formScrollView.autoresizingMask = [.width, .height]
        formScrollView.hasVerticalScroller = true
        formScrollView.autohidesScrollers = true
        formScrollView.drawsBackground = false
        formScrollView.borderType = .noBorder
        formDocument.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: 630)
        formDocument.autoresizingMask = [.width]
        formScrollView.documentView = formDocument
        content.addSubview(formScrollView)
        let heading = NSTextField(labelWithString: "划词助手")
        heading.font = .systemFont(ofSize: 23, weight: .semibold)
        let header = withHelp(heading, help: "在支持的 App 中选中文字，即可翻译或直接提问。")
        enabledButton.target = self
        enabledButton.action = #selector(enabledChanged)
        showMenuBarIconButton.target = self
        showMenuBarIconButton.action = #selector(showMenuBarIconChanged)
        menuBarVisibilityHint.font = .systemFont(ofSize: 11)
        menuBarVisibilityHint.textColor = .secondaryLabelColor
        menuBarVisibilityHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let visibilityGroup = vertical([
            enabledButton,
            withHelp(showMenuBarIconButton, help: "隐藏图标后，划词助手会保持开启，不能暂停。重新双击 Huaci.app 可打开设置，也可在设置中退出。"),
            menuBarVisibilityHint
        ], spacing: 7)

        popupAfterCopyButton.target = self
        popupAfterCopyButton.action = #selector(popupAfterCopyChanged)
        popupAfterCopyButton.state = store.settings.popupAfterCopy ? .on : .off
        let compatibilityGroup = withHelp(popupAfterCopyButton,
            help: "自动划词继续保留。无法自动取词时，选中文字后按 ⌘C，读取新复制的文字并显示翻译 / 问 AI。点击选项前不发送接口请求。")

        let pronunciationGroup = buildSpeechInterface()

        permissionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        permissionButton.bezelStyle = .rounded
        permissionButton.target = self
        permissionButton.action = #selector(requestPermission)
        let permissionHelp = SettingsHelpButton(help: "需要辅助功能权限，才能读取其他 App 的选中文字。如果系统开关已开启但仍不可用，请先重新检测，或使用「修复授权…」。")
        permissionHelp.setAccessibilityLabel("辅助功能授权说明")
        let permissionRow = NSStackView(views: [permissionLabel, permissionHelp, NSView(), permissionButton])
        permissionRow.orientation = .horizontal
        permissionRow.alignment = .centerY
        permissionRow.spacing = 8
        let refreshPermissionButton = NSButton(title: "重新检测", target: self, action: #selector(recheckPermission))
        let repairPermissionButton = NSButton(title: "修复授权…", target: self, action: #selector(repairPermission))
        for button in [refreshPermissionButton, repairPermissionButton] {
            button.bezelStyle = .rounded
        }
        let permissionActions = NSStackView(views: [refreshPermissionButton, repairPermissionButton])
        permissionActions.orientation = .horizontal
        permissionActions.spacing = 8
        let permissionGroup = vertical([permissionRow, permissionActions], spacing: 5)

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged)
        profilePopup.setAccessibilityLabel("正在编辑的 API 配置")
        let newProfileButton = NSButton(title: "新增", target: self, action: #selector(newProfileClicked))
        deleteProfileButton.target = self
        deleteProfileButton.action = #selector(deleteProfileClicked)
        for button in [newProfileButton, deleteProfileButton] { button.bezelStyle = .rounded }
        let profileRow = NSStackView(views: [profilePopup, newProfileButton, deleteProfileButton])
        profileRow.orientation = .horizontal
        profileRow.spacing = 8
        profilePopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let profileGroup = fieldGroup("API 配置", field: profileRow,
            help: "保存多套地址、模型和密钥。选择配置进行编辑，不会改变下方指定的用途。")
        profileNameField.placeholderString = "例如：DeepSeek 日常翻译"
        let profileNameGroup = fieldGroup("配置名称", field: profileNameField)
        for (popup, label) in [(translationProfilePopup, "翻译使用的配置"), (chatProfilePopup, "问 AI 使用的配置")] {
            popup.target = self
            popup.action = #selector(defaultProfileChanged)
            popup.setAccessibilityLabel(label)
        }
        let roleHelp = "用途选择立即保存，下次请求生效；可以为翻译和问 AI 指定不同配置。"
        let translationRole = fieldGroup("翻译使用", field: translationProfilePopup, help: roleHelp)
        let chatRole = fieldGroup("问 AI 使用", field: chatProfilePopup, help: roleHelp)
        let roleGroup = vertical([translationRole, chatRole], spacing: 10)
        translationRole.widthAnchor.constraint(equalTo: roleGroup.widthAnchor).isActive = true
        chatRole.widthAnchor.constraint(equalTo: roleGroup.widthAnchor).isActive = true

        baseURLField.placeholderString = "https://api.example.com/v1"
        modelField.placeholderString = "填写服务商提供的模型 ID"
        apiKeyField.placeholderString = "填写 API Key；本地服务可留空"
        for field in [profileNameField, baseURLField, apiKeyField, modelField] {
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.heightAnchor.constraint(equalToConstant: 29).isActive = true
        }
        let address = fieldGroup("API 地址", field: baseURLField,
            help: "兼容 OpenAI Chat Completions。可填基础地址或完整接口；仅本机服务支持 HTTP。")
        let key = fieldGroup("API Key", field: apiKeyField,
            help: "每套配置的密钥分别保存在 macOS 钥匙串中。AI 对话只保留在内存，主动导出时保存为文件。命中翻译缓存或本机确认原文已是目标语言时，不请求接口。")
        let model = fieldGroup("模型名称", field: modelField)

        let balanceHeading = NSTextField(labelWithString: "API 余额")
        balanceHeading.font = .systemFont(ofSize: 12, weight: .medium)
        balanceProviderLabel.font = .systemFont(ofSize: 12)
        balanceProviderLabel.textColor = .secondaryLabelColor
        balanceAmountLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        for label in [balanceAmountLabel, balanceStatusLabel, balanceUpdatedLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.isSelectable = true
        }
        balanceStatusLabel.font = .systemFont(ofSize: 11)
        balanceUpdatedLabel.font = .systemFont(ofSize: 11)
        balanceUpdatedLabel.textColor = .secondaryLabelColor
        balanceRefreshButton.bezelStyle = .rounded
        balanceRefreshButton.target = self
        balanceRefreshButton.action = #selector(refreshBalanceClicked)
        balanceAccountButton.bezelStyle = .rounded
        balanceAccountButton.target = self
        balanceAccountButton.action = #selector(balanceAccountClicked)
        let balanceActions = NSStackView(views: [balanceRefreshButton, balanceAccountButton])
        balanceActions.orientation = .horizontal
        balanceActions.spacing = 8
        balanceActions.detachesHiddenViews = true
        let balanceGroup = vertical([
            withHelp(balanceHeading, help: "查询已保存 API Key 所属账户的余额，不产生模型调用；其他应用的消费也会计入。DeepSeek 支持直接查询；OpenAI 请前往官方账单，其他平台暂未适配。"),
            balanceProviderLabel, balanceAmountLabel,
            balanceStatusLabel, balanceUpdatedLabel, balanceActions
        ], spacing: 6)

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        testButton.bezelStyle = .rounded
        testButton.target = self
        testButton.action = #selector(testClicked)
        let buttons = NSStackView(views: [saveButton, testButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.isHidden = true
        let quitButton = NSButton(title: "退出划词助手", target: self, action: #selector(quitClicked))
        quitButton.bezelStyle = .rounded
        let footer = vertical([
            buttons,
            hint("测试连接会发送请求，可能消耗少量额度。"),
            statusLabel
        ], spacing: 10)

        let cacheGroup = buildCacheInterface()
        let sections: [NSView] = [header, visibilityGroup, compatibilityGroup,
            permissionGroup, separator(), profileGroup, profileNameGroup, address, key, model,
            balanceGroup, footer, roleGroup, separator(), cacheGroup, separator(), pronunciationGroup,
            separator(), quitButton]
        let stack = vertical(sections, spacing: 15)
        formStack = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        formDocument.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: formDocument.topAnchor, constant: 25),
            stack.leadingAnchor.constraint(equalTo: formDocument.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: formDocument.trailingAnchor, constant: -28)
        ])
        for view in sections where view is NSStackView {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        permissionRow.widthAnchor.constraint(equalTo: permissionGroup.widthAnchor).isActive = true
        refreshPreferenceControls()
        refreshPermission()
        renderBalance()
        resizeForm()
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        // Keep hidden status labels attached while their width constraints are active.
        stack.detachesHiddenViews = false
        for view in views {
            stack.addArrangedSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            if view is NSTextField || view is NSBox {
                view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            } else {
                view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
            }
        }
        return stack
    }

    private func buildSpeechInterface() -> NSStackView {
        let title = NSTextField(labelWithString: "英文单词发音")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        englishAccentPopup.addItems(withTitles: EnglishAccent.allCases.map(\.title))
        englishAccentPopup.target = self
        englishAccentPopup.action = #selector(englishAccentChanged)
        englishAccentPopup.setAccessibilityLabel("系统语音英文发音口音")
        let accent = fieldGroup("发音口音", field: englishAccentPopup,
            help: "使用 Mac 已安装的系统语音，修改口音后自动保存。缺少对应语音时，请先在 macOS 系统朗读设置中下载。")

        speechPreviewButton.target = self
        speechPreviewButton.action = #selector(previewSpeechClicked)
        speechPreviewButton.toolTip = "使用所选口音朗读 apple。"
        speechStopButton.target = self
        speechStopButton.action = #selector(stopSpeechPreviewClicked)
        speechStopButton.isEnabled = false
        for button in [speechPreviewButton, speechStopButton] { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [speechPreviewButton, speechStopButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        speechStatusLabel.font = .systemFont(ofSize: 11)
        speechStatusLabel.isHidden = true
        let group = vertical([title, accent, actions, speechStatusLabel], spacing: 10)
        accent.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        speechGroup = group
        englishAccentPopup.selectItem(withTitle: store.settings.englishAccent.title)
        return group
    }

    func showSpeechSettings() {
        show()
        resizeForm()
        if let speechGroup {
            formDocument.scrollToVisible(speechGroup.convert(speechGroup.bounds, to: formDocument))
        }
        window?.makeFirstResponder(englishAccentPopup)
    }

    private var selectedEnglishAccent: EnglishAccent {
        let index = englishAccentPopup.indexOfSelectedItem
        return EnglishAccent.allCases.indices.contains(index)
            ? EnglishAccent.allCases[index] : store.settings.englishAccent
    }

    private func loadSpeechSettings() {
        stopSpeechPreview()
        englishAccentPopup.selectItem(withTitle: store.settings.englishAccent.title)
        setSpeechStatus("")
    }

    private func setSpeechStatus(_ text: String, error: Bool = false) {
        speechStatusLabel.stringValue = text
        speechStatusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        speechStatusLabel.isHidden = text.isEmpty
        resizeForm()
    }

    func stopSpeechPreview() {
        let wasActive = speechStopButton.isEnabled
        speechPreviewController.stop()
        speechStopButton.isEnabled = false
        if wasActive { setSpeechStatus("已停止试听。") }
    }

    @objc private func previewSpeechClicked() {
        stopSpeechPreview()
        onPreviewSpeech?()
        do {
            try speechPreviewController.speak(word: "apple", accent: selectedEnglishAccent)
            speechStopButton.isEnabled = true
            setSpeechStatus("已使用系统语音朗读 apple。")
        } catch {
            setSpeechStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func stopSpeechPreviewClicked() {
        stopSpeechPreview()
        setSpeechStatus("已停止试听。")
    }

    private func buildCacheInterface() -> NSStackView {
        let title = NSTextField(labelWithString: "翻译缓存与历史")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        cacheEnabledButton.target = self
        cacheEnabledButton.action = #selector(cachePreferenceChanged)
        historyEnabledButton.target = self
        historyEnabledButton.action = #selector(cachePreferenceChanged)
        for field in [cacheEntriesField, cacheMegabytesField] {
            field.font = .systemFont(ofSize: 13)
            field.bezelStyle = .roundedBezel
            field.delegate = self
            field.target = self
            field.action = #selector(cacheLimitCommitted)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
            field.heightAnchor.constraint(equalToConstant: 29).isActive = true
        }
        cacheEntriesField.setAccessibilityLabel("翻译缓存最大条数，1 到 10000 条")
        cacheMegabytesField.setAccessibilityLabel("翻译缓存文本总量，1 到 100 MB")
        let entriesHelp = "默认 200 条，可设为 1–10,000 条。数值越大，可复用的翻译结果越多；降低后会移除超出上限的旧缓存。条数或文本总量任一达到上限时，清理最久未使用的记录。按回车或结束编辑后自动保存；不影响历史与收藏。"
        let megabytesHelp = "默认 5 MB，可设为 1–100 MB。限制原文、译文、词典内容及缓存元信息的 UTF-8 文本数据总量；1 MB = 1,000,000 字节。数值越大，可缓存更多或更长的结果，不会预先占满。它不是 App 总内存上限，还会有对象等开销。按回车或结束编辑后自动保存；不影响历史与收藏。"
        let entries = cacheLimitRow("最大条数", field: cacheEntriesField, unit: "条（1–10,000）", help: entriesHelp)
        let megabytes = cacheLimitRow("文本总量", field: cacheMegabytesField, unit: "MB（1–100）", help: megabytesHelp)
        let clearCache = NSButton(title: "清空缓存", target: self, action: #selector(clearCacheClicked))
        let openHistory = NSButton(title: "翻译历史与收藏…", target: self, action: #selector(openHistoryClicked))
        for button in [clearCache, openHistory] { button.bezelStyle = .rounded }
        let actions = NSStackView(views: [clearCache, openHistory])
        actions.orientation = .horizontal
        actions.spacing = 8
        cacheStatusLabel.font = .systemFont(ofSize: 11)
        cacheStatusLabel.isHidden = true
        let group = vertical([title,
            withHelp(cacheEnabledButton, help: "开关立即保存。相同原文、目标语言和 API 配置可复用成功结果，减少等待和 API 调用；「重试」会重新请求。缓存按实际内容占用内存，关闭缓存或退出 App 后清空。关闭时仍可调整下次启用的额度。"),
            entries, megabytes,
            withHelp(historyEnabledButton, help: "开关立即保存。历史与收藏保存在本机，退出后保留。关闭历史只停止新增记录，已有记录可在历史窗口清除，收藏仍可手动添加；不受缓存条数和文本总量限制。"),
            actions, cacheStatusLabel], spacing: 10)
        entries.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        megabytes.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func cacheLimitRow(_ title: String, field: NSTextField, unit: String, help: String) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let info = SettingsHelpButton(help: help)
        info.setAccessibilityLabel("\(title)说明")
        field.setAccessibilityHelp(help)
        let row = NSStackView(views: [label, info, NSView(), field, hint(unit)])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        return row
    }

    private func withHelp(_ view: NSView, help: String) -> NSStackView {
        let info = SettingsHelpButton(help: help)
        if let label = view as? NSTextField {
            info.setAccessibilityLabel("\(label.stringValue)说明")
        } else if let button = view as? NSButton {
            info.setAccessibilityLabel("\(button.title)说明")
        }
        view.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(views: [view, info, NSView()])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        return row
    }

    private func hint(_ text: String, size: CGFloat = 11) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func fieldGroup(_ title: String, field: NSView, help: String? = nil) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let heading: NSView
        if let help { heading = withHelp(label, help: help) }
        else { heading = label }
        let group = vertical([heading, field], spacing: 6)
        field.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return box
    }

    private func loadSettings() {
        loadTranslationPreferences()
        loadSpeechSettings()
        refreshPreferenceControls()
        let profile = store.settings.profiles.first(where: { $0.id == editingProfileID })
            ?? store.profile(for: .translation)
        loadProfile(profile)
    }

    private func loadProfile(_ profile: APIProfile) {
        cancelTest()
        cancelBalance()
        editingProfileID = profile.id
        profileHasChanges = false
        profileNameField.stringValue = profile.name
        baseURLField.stringValue = profile.baseURL
        modelField.stringValue = profile.model
        refreshProfileMenus()
        do {
            apiKeyField.stringValue = try store.loadAPIKey(profileID: profile.id)
            resetBalance(savedKey: apiKeyField.stringValue)
            setStatus("")
        } catch {
            apiKeyField.stringValue = ""
            resetBalance(savedKey: nil, keyError: error.localizedDescription)
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func refreshProfileMenus() {
        for popup in [profilePopup, translationProfilePopup, chatProfilePopup] {
            popup.removeAllItems()
            if popup.menu == nil { popup.menu = NSMenu() }
            for profile in store.settings.profiles {
                let item = NSMenuItem(title: profile.name, action: nil, keyEquivalent: "")
                item.representedObject = profile.id
                popup.menu?.addItem(item)
            }
        }
        if editingProfileID == nil {
            let item = NSMenuItem(title: "新配置（尚未保存）", action: nil, keyEquivalent: "")
            profilePopup.menu?.addItem(item)
            profilePopup.select(item)
        } else {
            selectProfile(editingProfileID, in: profilePopup)
        }
        selectProfile(store.settings.translationProfileID, in: translationProfilePopup)
        selectProfile(store.settings.chatProfileID, in: chatProfilePopup)
        deleteProfileButton.isEnabled = editingProfileID != nil && store.settings.profiles.count > 1
        deleteProfileButton.toolTip = store.settings.profiles.count > 1 ? nil : "至少保留一套 API 配置。"
    }

    private func selectProfile(_ id: String?, in popup: NSPopUpButton) {
        guard let item = popup.itemArray.first(where: { ($0.representedObject as? String) == id }) else { return }
        popup.select(item)
    }

    private func confirmLeavingProfile() -> Bool {
        guard profileHasChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "保存当前 API 配置的修改？"
        alert.informativeText = "当前配置有未保存的修改。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "不保存")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveSettings()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @objc private func profileChanged() {
        guard let id = profilePopup.selectedItem?.representedObject as? String,
              id != editingProfileID,
              let profile = store.settings.profiles.first(where: { $0.id == id }) else { return }
        guard confirmLeavingProfile() else {
            refreshProfileMenus()
            return
        }
        loadProfile(profile)
        refreshBalance()
    }

    @objc private func newProfileClicked() {
        guard confirmLeavingProfile() else { return }
        cancelTest()
        cancelBalance()
        editingProfileID = nil
        profileHasChanges = true
        profileNameField.stringValue = "新配置"
        baseURLField.stringValue = ""
        modelField.stringValue = ""
        apiKeyField.stringValue = ""
        savedBalanceConfiguration = nil
        balanceState.reset(provider: .unconfigured, requiresSave: true)
        refreshProfileMenus()
        renderBalance()
        setStatus("填写并保存新配置后，可在用途选择中使用。")
        window?.makeFirstResponder(profileNameField)
        formDocument.scrollToVisible(profileNameField.convert(profileNameField.bounds, to: formDocument))
    }

    @objc private func deleteProfileClicked() {
        guard let id = editingProfileID,
              let profile = store.settings.profiles.first(where: { $0.id == id }),
              store.settings.profiles.count > 1 else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除「\(profile.name)」？"
        alert.informativeText = "这会删除该配置及其钥匙串密钥。若当前有未保存的修改，也会丢弃。使用该配置的用途将改用其他已保存配置。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "删除配置")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do {
            try store.deleteProfile(id: id)
            loadProfile(store.profile(for: .translation))
            refreshBalance()
            setStatus("已删除配置，请核对翻译与问 AI 的用途选择。")
        } catch {
            setStatus(error.localizedDescription, error: true)
        }
    }

    @objc private func defaultProfileChanged() {
        guard let translationID = translationProfilePopup.selectedItem?.representedObject as? String,
              let chatID = chatProfilePopup.selectedItem?.representedObject as? String else { return }
        do {
            try store.setDefaultProfiles(translationID: translationID, chatID: chatID)
            setStatus("已保存用途选择，下次翻译或问 AI 时生效。")
        } catch {
            refreshProfileMenus()
            setStatus(error.localizedDescription, error: true)
        }
    }

    private func loadTranslationPreferences() {
        cacheEnabledButton.state = store.settings.cacheEnabled ? .on : .off
        cacheEntriesField.stringValue = String(store.settings.cacheMaxEntries)
        cacheMegabytesField.stringValue = String(store.settings.cacheMaxMegabytes)
        historyEnabledButton.state = store.settings.historyEnabled ? .on : .off
        updateCacheControls()
        setCacheStatus("")
    }

    private func cacheLimitDraft(_ field: NSTextField) -> Int? {
        let text = field.currentEditor()?.string ?? field.stringValue
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var invalidCacheLimitField: NSTextField? {
        guard let entries = cacheLimitDraft(cacheEntriesField), (1...10_000).contains(entries) else {
            return cacheEntriesField
        }
        guard let megabytes = cacheLimitDraft(cacheMegabytesField), (1...100).contains(megabytes) else {
            return cacheMegabytesField
        }
        return nil
    }

    /// Used for both closing this window and quitting the app while a numeric
    /// field still owns the field editor. Other settings remain independent.
    @discardableResult
    func commitTranslationPreferencesBeforeClosing() -> Bool {
        guard isWindowLoaded, let window, window.isVisible else { return true }
        guard saveTranslationPreferences() else {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            if let field = invalidCacheLimitField {
                window.makeFirstResponder(field)
                formDocument.scrollToVisible(field.convert(field.bounds, to: formDocument))
            }
            return false
        }
        return true
    }

    private func updateCacheControls() {
        // Keep limits editable when caching is off: users can fix an unfinished
        // value or prepare the next enabled session without toggling caching on.
        cacheEntriesField.isEnabled = true
        cacheMegabytesField.isEnabled = true
    }

    private func setCacheStatus(_ text: String, error: Bool = false) {
        cacheStatusLabel.stringValue = text
        cacheStatusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        cacheStatusLabel.isHidden = text.isEmpty
        resizeForm()
    }

    @objc private func cachePreferenceChanged() {
        updateCacheControls()
        let cacheEnabled = cacheEnabledButton.state == .on
        let historyEnabled = historyEnabledButton.state == .on
        guard cacheEnabled != store.settings.cacheEnabled || historyEnabled != store.settings.historyEnabled else { return }
        do {
            // Checkboxes take effect even when a numeric field contains an
            // unfinished draft. Preserve both its text and validation message.
            try store.saveTranslationPreferences(cacheEnabled: cacheEnabled,
                maxEntries: store.settings.cacheMaxEntries,
                maxMegabytes: store.settings.cacheMaxMegabytes, historyEnabled: historyEnabled)
        } catch {
            cacheEnabledButton.state = store.settings.cacheEnabled ? .on : .off
            historyEnabledButton.state = store.settings.historyEnabled ? .on : .off
            setCacheStatus(error.localizedDescription, error: true)
        }
    }

    @discardableResult
    private func saveTranslationPreferences() -> Bool {
        guard let entries = cacheLimitDraft(cacheEntriesField),
              (1...10_000).contains(entries),
              let megabytes = cacheLimitDraft(cacheMegabytesField),
              (1...100).contains(megabytes) else {
            setCacheStatus("请输入整数：最大条数为 1–10,000，文本总量为 1–100 MB。", error: true)
            formDocument.scrollToVisible(cacheStatusLabel.convert(cacheStatusLabel.bounds, to: formDocument))
            return false
        }
        do {
            let cacheEnabled = cacheEnabledButton.state == .on
            let historyEnabled = historyEnabledButton.state == .on
            if cacheEnabled != store.settings.cacheEnabled || historyEnabled != store.settings.historyEnabled
                || entries != store.settings.cacheMaxEntries || megabytes != store.settings.cacheMaxMegabytes {
                try store.saveTranslationPreferences(cacheEnabled: cacheEnabled,
                    maxEntries: entries, maxMegabytes: megabytes, historyEnabled: historyEnabled)
            }
            cacheEntriesField.stringValue = String(entries)
            cacheMegabytesField.stringValue = String(megabytes)
            setCacheStatus("")
            return true
        } catch {
            setCacheStatus(error.localizedDescription, error: true)
            return false
        }
    }

    @objc private func cacheLimitCommitted() {
        saveTranslationPreferences()
    }

    @objc private func clearCacheClicked() {
        onClearTranslationCache?()
        setCacheStatus("已清空翻译缓存；翻译历史与收藏不受影响。")
    }

    @objc private func openHistoryClicked() {
        onOpenTranslationHistory?()
    }

    func refreshPermission() {
        let granted = permissionStatus()
        permissionLabel.stringValue = granted ? "辅助功能：已授权" : "辅助功能：当前 App 未获授权"
        permissionLabel.textColor = granted ? .labelColor : .secondaryLabelColor
        permissionButton.isEnabled = true
    }

    private func refreshPreferenceControls() {
        let visible = store.settings.showMenuBarIcon
        enabledButton.state = store.settings.enabled ? .on : .off
        enabledButton.isEnabled = visible
        enabledButton.toolTip = visible ? nil : "显示菜单栏图标后，才可以暂停划词助手。"
        showMenuBarIconButton.state = visible ? .on : .off
        popupAfterCopyButton.state = store.settings.popupAfterCopy ? .on : .off
        menuBarVisibilityHint.stringValue = "图标已隐藏，助手保持开启。双击 Huaci.app 可打开设置。"
        menuBarVisibilityHint.isHidden = visible
        resizeForm()
    }

    private func setStatus(_ text: String, error: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
        statusLabel.isHidden = text.isEmpty
        resizeForm()
        if !text.isEmpty {
            formDocument.scrollToVisible(statusLabel.convert(statusLabel.bounds, to: formDocument))
        }
    }

    private func resizeForm() {
        guard let stack = formStack else { return }
        formScrollView.layoutSubtreeIfNeeded()
        formDocument.setFrameSize(NSSize(width: formScrollView.contentSize.width, height: formDocument.frame.height))
        formDocument.layoutSubtreeIfNeeded()
        let height = max(ceil(stack.fittingSize.height) + 45, formScrollView.contentSize.height)
        formDocument.setFrameSize(NSSize(width: formScrollView.contentSize.width, height: height))
        formDocument.layoutSubtreeIfNeeded()
    }

    private func cancelTest() {
        testGeneration += 1
        testTask?.cancel()
        testTask = nil
        testButton.title = "保存并测试连接"
        testButton.isEnabled = true
    }

    private func cancelBalance() {
        balanceTask?.cancel()
        balanceTask = nil
        balanceState.cancel()
    }

    private func resetBalance(savedKey: String?, keyError: String? = nil) {
        cancelBalance()
        savedBalanceConfiguration = nil
        balanceState.reset(provider: .detect(baseURL: baseURLField.stringValue), requiresSave: false)
        if balanceState.provider.supportsQuery {
            if let key = savedKey {
                do {
                    savedBalanceConfiguration = try APIConfiguration.validated(
                        baseURL: baseURLField.stringValue, apiKey: key, model: modelField.stringValue)
                } catch {
                    if let requestID = balanceState.begin() {
                        balanceState.fail(message: error.localizedDescription, for: requestID)
                    }
                }
            } else if let requestID = balanceState.begin() {
                balanceState.fail(message: keyError ?? "无法读取已保存的 API Key，请重试。", for: requestID)
            }
        }
        renderBalance()
    }

    private func renderBalance() {
        let state = balanceState
        balanceProviderLabel.stringValue = state.provider.title
        balanceRefreshButton.isHidden = !state.provider.supportsQuery
        balanceRefreshButton.isEnabled = state.provider.supportsQuery && !state.requiresSave && !state.isLoading
        balanceRefreshButton.title = state.isLoading ? "正在查询…" : "刷新余额"
        balanceAccountButton.isHidden = state.provider.accountURL == nil
        balanceAccountButton.isEnabled = !state.requiresSave
        balanceAccountButton.title = state.provider == .openAI ? "前往官方账单" : "账户后台"
        balanceAmountLabel.stringValue = ""
        balanceAmountLabel.toolTip = nil
        balanceUpdatedLabel.stringValue = ""
        balanceStatusLabel.textColor = .secondaryLabelColor
        balanceStatusLabel.toolTip = nil

        if state.requiresSave {
            balanceStatusLabel.stringValue = "API 配置已修改，请先保存后查询余额。"
        } else {
            switch state.provider {
            case .unconfigured:
                balanceStatusLabel.stringValue = "填写并保存 API 配置后，可识别余额查询方式。"
            case .unsupported:
                balanceStatusLabel.stringValue = "此平台暂不支持余额查询。"
            case .openAI:
                balanceStatusLabel.stringValue = "暂不支持在应用内查询余额，请前往官方账单查看。"
                balanceStatusLabel.toolTip = "OpenAI 当前官方公开接口未提供普通 API Key 的余额查询。"
            case .deepSeek:
                if let snapshot = state.snapshot {
                    balanceAmountLabel.stringValue = snapshot.balances.map {
                        "可用余额：\($0.currency) \($0.total)"
                    }.joined(separator: "\n")
                    balanceAmountLabel.toolTip = snapshot.balances.map {
                        "\($0.currency) · 赠金 \($0.granted) · 充值余额 \($0.toppedUp)"
                    }.joined(separator: "\n")
                    let time = DateFormatter.localizedString(from: snapshot.fetchedAt,
                        dateStyle: .short, timeStyle: .medium)
                    balanceUpdatedLabel.stringValue = "上次成功查询：\(time)"
                    balanceStatusLabel.stringValue = snapshot.isAvailable
                        ? ""
                        : "账户余额当前不可用，请前往账户后台查看。"
                } else {
                    balanceStatusLabel.stringValue = ""
                }
                if state.isLoading {
                    balanceStatusLabel.stringValue = state.snapshot == nil
                        ? "正在查询账户余额…"
                        : "正在刷新…当前显示上次查询结果。"
                } else if let error = state.errorMessage {
                    balanceStatusLabel.textColor = .systemRed
                    balanceStatusLabel.stringValue = "暂时无法查询：\(error)"
                    if state.snapshot != nil {
                        balanceUpdatedLabel.stringValue += "（刷新失败，保留旧余额）"
                    }
                }
            }
        }
        balanceAmountLabel.isHidden = balanceAmountLabel.stringValue.isEmpty
        balanceStatusLabel.isHidden = balanceStatusLabel.stringValue.isEmpty
        balanceUpdatedLabel.isHidden = balanceUpdatedLabel.stringValue.isEmpty
        resizeForm()
    }

    private func refreshBalance() {
        guard let configuration = savedBalanceConfiguration,
              let requestID = balanceState.begin() else { return }
        renderBalance()
        balanceTask = Task { [weak self] in
            do {
                let snapshot = try await APIBalance.fetch(configuration: configuration)
                try Task.checkCancellation()
                guard let self, self.balanceState.activeRequestID == requestID else { return }
                self.balanceState.complete(snapshot: snapshot, for: requestID)
            } catch {
                guard !Task.isCancelled, let self,
                      self.balanceState.activeRequestID == requestID else { return }
                self.balanceState.fail(message: error.localizedDescription, for: requestID)
            }
            guard let self else { return }
            self.balanceTask = nil
            self.renderBalance()
        }
    }

    @objc private func refreshBalanceClicked() {
        guard !balanceState.requiresSave, !balanceState.isLoading,
              balanceState.provider.supportsQuery else { return }
        // A manual refresh may retry an earlier Keychain failure. Opening the
        // window never retries a failed Keychain read automatically.
        if savedBalanceConfiguration == nil {
            do {
                guard let id = editingProfileID else { return }
                savedBalanceConfiguration = try store.configuration(profileID: id)
            } catch {
                if let requestID = balanceState.begin() {
                    balanceState.fail(message: error.localizedDescription, for: requestID)
                }
                renderBalance()
                return
            }
        }
        refreshBalance()
    }

    @objc private func balanceAccountClicked() {
        guard !balanceState.requiresSave, let url = balanceState.provider.accountURL else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    private func saveSettings() -> Bool {
        cancelTest()
        do {
            let id = try store.saveProfile(id: editingProfileID, name: profileNameField.stringValue,
                baseURL: baseURLField.stringValue, model: modelField.stringValue, apiKey: apiKeyField.stringValue)
            editingProfileID = id
            profileHasChanges = false
            if let profile = store.settings.profiles.first(where: { $0.id == id }) {
                profileNameField.stringValue = profile.name
                baseURLField.stringValue = profile.baseURL
                modelField.stringValue = profile.model
            }
            refreshProfileMenus()
            resetBalance(savedKey: apiKeyField.stringValue)
            refreshBalance()
            setStatus("已保存当前配置；翻译和问 AI 按下方用途选择使用。")
            return true
        } catch {
            setStatus(error.localizedDescription, error: true)
            return false
        }
    }

    @objc private func enabledChanged() {
        cancelTest()
        let enabled = enabledButton.state == .on
        store.setEnabled(enabled)
        refreshPreferenceControls()
        setStatus(store.settings.enabled ? "已启用划词助手。" : "已暂停划词助手。")
    }

    @objc private func showMenuBarIconChanged() {
        cancelTest()
        store.setShowMenuBarIcon(showMenuBarIconButton.state == .on)
        refreshPreferenceControls()
        setStatus(store.settings.showMenuBarIcon
            ? "已显示菜单栏图标，可以按需暂停划词助手。"
            : "已隐藏菜单栏图标，划词助手保持开启。重新双击 Huaci.app 可打开设置。")
    }

    @objc private func quitClicked() {
        if let window, !windowShouldClose(window) { return }
        stopSpeechPreview()
        cancelTest()
        cancelBalance()
        NSApp.terminate(nil)
    }

    @objc private func popupAfterCopyChanged() {
        cancelTest()
        let enabled = popupAfterCopyButton.state == .on
        store.setPopupAfterCopy(enabled)
        popupAfterCopyButton.state = store.settings.popupAfterCopy ? .on : .off
        setStatus(enabled
            ? "兼容模式已开启，自动划词继续保留。无法自动取词时，可选中文字后按 ⌘C。"
            : "兼容模式已关闭，自动划词继续保留；复制文字时不再额外弹出选项。")
    }

    @objc private func englishAccentChanged() {
        stopSpeechPreview()
        store.setEnglishAccent(selectedEnglishAccent)
        setSpeechStatus("已保存发音口音。")
    }

    @objc private func requestPermission() {
        onRequestPermission()
        refreshPermission()
    }

    @objc private func recheckPermission() {
        onRefreshPermission()
        refreshPermission()
    }

    @objc private func repairPermission() {
        onRepairPermission()
        refreshPermission()
    }

    @objc private func saveClicked() {
        cancelTest()
        saveSettings()
    }

    @objc private func testClicked() {
        cancelTest()
        guard saveSettings() else { return }
        let configuration: APIConfiguration
        do {
            guard let id = editingProfileID else { return }
            configuration = try store.configuration(profileID: id)
        }
        catch {
            setStatus(error.localizedDescription, error: true)
            return
        }
        let generation = testGeneration
        testButton.title = "正在测试…"
        testButton.isEnabled = false
        setStatus("正在连接接口…")
        testTask = Task { [weak self] in
            do {
                try await APIClient.stream(configuration: configuration, mode: .ask,
                    text: "请只回复：连接成功", onDelta: { _ in })
                try Task.checkCancellation()
                guard let self = self, self.testGeneration == generation else { return }
                self.setStatus("连接成功，接口可以正常返回内容。")
            } catch {
                guard !Task.isCancelled, let self = self, self.testGeneration == generation else { return }
                self.setStatus(error.localizedDescription, error: true)
            }
            guard let self = self, self.testGeneration == generation else { return }
            self.testTask = nil
            self.testButton.title = "保存并测试连接"
            self.testButton.isEnabled = true
        }
    }
}
