import AppKit
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let selectionMonitor = SelectionMonitor()
    private let panel = AssistantPanelController()
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem?
    private var enableItem: NSMenuItem?
    private var permissionItem: NSMenuItem?
    private var permissionTimer: Timer?
    private var trusted = false
    private var selectedText = ""
    private var selectedPoint: NSPoint?
    private var selectedMode = CompletionMode.translate
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var translationOutput = ""
    private var translationReturnedModel: String?
    private var currentTranslation: SavedTranslation?
    private let translationCache = TranslationCache()
    private let translationHistory = TranslationHistoryStore()
    private lazy var historyWindow = TranslationHistoryWindowController(store: translationHistory)
    private let chatWindow = ChatWindowController()
    private var conversation = ConversationState()
    private var chatTask: Task<Void, Never>?
    private var chatRequestID = UUID()
    private var chatReturnedModel: String?
    private var chatRenderScheduled = false

    private lazy var permissionRecovery = PermissionRecoveryController(
        onRefresh: { [weak self] in self?.refreshPermission(reinstallMonitors: true) }
    )

    private lazy var settingsWindow = SettingsWindowController(
        store: store,
        permissionStatus: { [weak self] in self?.trusted ?? false },
        onRequestPermission: { [weak self] in self?.requestAccessibility() },
        onRefreshPermission: { [weak self] in self?.refreshPermission(reinstallMonitors: true) },
        onRepairPermission: { [weak self] in self?.permissionRecovery.show() }
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        configureStatusMenu()
        selectionMonitor.enabled = store.settings.enabled
        selectionMonitor.popupAfterCopy = store.settings.popupAfterCopy
        selectionMonitor.onSelection = { [weak self] text, point in self?.offer(text: text, near: point) }
        selectionMonitor.onDismiss = { [weak self] in
            guard let self, !self.panel.isPinned else { return }
            self.dismissPanel()
        }
        selectionMonitor.onEscape = { [weak self] in self?.dismissPanel() }
        selectionMonitor.onUnavailable = { [weak self] message in self?.showNotice(message) }
        panel.onAction = { [weak self] mode in
            if mode == .ask { self?.openChatFromSelection() }
            else { self?.run(mode: .translate) }
        }
        panel.setTargetLanguage(TranslationLanguage(rawValue: store.settings.translationTarget) ?? .simplifiedChinese)
        panel.englishAccentProvider = { [weak self] in self?.store.settings.englishAccent ?? .american }
        panel.onPronunciationStart = { [weak self] in self?.settingsWindow.stopSpeechPreview() }
        settingsWindow.onPreviewSpeech = { [weak self] in self?.panel.stopPronunciation() }
        store.onSpeechSettingsChange = { [weak self] in
            self?.panel.stopPronunciation()
            self?.settingsWindow.stopSpeechPreview()
        }
        panel.onTargetLanguageChange = { [weak self] language in
            guard let self = self else { return }
            self.store.setTranslationTarget(language)
            self.panel.setTargetLanguage(language)
            if !self.selectedText.isEmpty { self.run(mode: .translate) }
        }
        panel.onClose = { [weak self] in self?.dismissPanel() }
        panel.onStop = { [weak self] in self?.stopGeneration() }
        panel.onRetry = { [weak self] in
            guard let self = self else { return }
            self.run(mode: self.selectedMode, bypassCache: true)
        }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onToggleFavorite = { [weak self] in self?.toggleCurrentFavorite() }
        settingsWindow.onClearTranslationCache = { [weak self] in self?.translationCache.removeAll() }
        settingsWindow.onOpenTranslationHistory = { [weak self] in self?.openTranslationHistory() }
        historyWindow.onOpen = { [weak self] record in self?.showSavedTranslation(record) }
        translationHistory.onChange = { [weak self] in
            self?.historyWindow.reload()
            self?.updateFavoriteButton()
        }
        store.onTranslationPreferencesChange = { [weak self] in self?.configureTranslationCache() }
        configureTranslationCache()
        chatWindow.onSend = { [weak self] question in self?.sendChat(question: question) }
        chatWindow.onStop = { [weak self] in self?.stopChatGeneration() }
        chatWindow.onRetry = { [weak self] in self?.retryChat() }
        chatWindow.onClose = { [weak self] in self?.stopChatGeneration() }
        chatWindow.onClear = { [weak self] in
            guard let self = self else { return }
            self.stopChatGeneration()
            self.conversation.clear()
            self.chatWindow.setSelectionContext("")
            self.chatReturnedModel = nil
            self.renderChat()
        }
        chatWindow.onExport = { [weak self] in
            guard let self, !self.conversation.turns.isEmpty else { return }
            let date = Date()
            let markdown = ConversationMarkdown.render(self.conversation, exportedAt: date)
            self.chatWindow.exportMarkdown(markdown,
                suggestedFilename: ConversationMarkdown.suggestedFilename(exportedAt: date))
        }
        chatWindow.onOpenSettings = { [weak self] in self?.openSettings() }
        store.onVisibilityChange = { [weak self] in
            guard let self else { return }
            // Hiding a paused app resumes selection, but a visual preference
            // must not interrupt an AI response or clear its conversation.
            self.selectionMonitor.enabled = self.store.settings.enabled
            self.updateMenu()
        }
        store.onChange = { [weak self] in
            guard let self = self else { return }
            // Credential changes must invalidate hits even when the URL/model
            // are unchanged. No credential is retained in a cache key.
            self.translationCache.removeAll()
            self.selectionMonitor.enabled = self.store.settings.enabled
            self.selectionMonitor.popupAfterCopy = self.store.settings.popupAfterCopy
            self.selectionMonitor.invalidate()
            self.dismissPanel()
            self.stopChatGeneration()
            self.chatReturnedModel = nil
            self.renderChat()
            self.updateMenu()
        }
        trusted = AXIsProcessTrusted()
        selectionMonitor.start()
        hotKey = GlobalHotKey()
        hotKey?.onPress = { [weak self] in self?.selectionMonitor.requestSelection(explicit: true) }
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermission() }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
        updateMenu()
        if !store.settings.showMenuBarIcon || store.settings.baseURL.isEmpty || store.settings.model.isEmpty || !trusted {
            DispatchQueue.main.async { [weak self] in self?.openSettings() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        settingsWindow.commitTranslationPreferencesBeforeClosing() ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        refreshPermission(reinstallMonitors: true)
        openSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermission(reinstallMonitors: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        panel.stopPronunciation()
        settingsWindow.stopSpeechPreview()
        task?.cancel()
        chatTask?.cancel()
        permissionTimer?.invalidate()
        selectionMonitor.stop()
        hotKey?.stop()
    }

    private func configureStatusMenu() {
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.isVisible = store.settings.showMenuBarIcon
        if let icon = NSImage(systemSymbolName: "character.cursor.ibeam", accessibilityDescription: "划词助手") {
            icon.isTemplate = true
            status.button?.image = icon
        } else {
            status.button?.title = "译"
        }
        status.button?.toolTip = "划词助手 · 翻译 / 问 AI"
        let menu = NSMenu()
        menu.delegate = self
        let label = NSMenuItem(title: "划词助手", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        let enable = menu.addItem(withTitle: "启用划词", action: #selector(toggleEnabled), keyEquivalent: "")
        enable.target = self
        enableItem = enable
        let read = menu.addItem(withTitle: "读取当前选区    ⌃⌥空格", action: #selector(readSelection), keyEquivalent: "")
        read.target = self
        let clipboard = menu.addItem(withTitle: "使用剪贴板文字", action: #selector(readClipboard), keyEquivalent: "")
        clipboard.target = self
        let chat = menu.addItem(withTitle: "打开 AI 对话…", action: #selector(openChatWindow), keyEquivalent: "")
        chat.target = self
        let history = menu.addItem(withTitle: "翻译历史与收藏…", action: #selector(openTranslationHistory), keyEquivalent: "")
        history.target = self
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        let permission = menu.addItem(withTitle: "辅助功能权限…", action: #selector(requestAccessibility), keyEquivalent: "")
        permission.target = self
        permissionItem = permission
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出划词助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
        statusItem = status
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "划词助手")
        let settings = appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出划词助手", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) { refreshPermission() }

    private func updateMenu() {
        if statusItem?.isVisible != store.settings.showMenuBarIcon {
            statusItem?.isVisible = store.settings.showMenuBarIcon
        }
        enableItem?.state = store.settings.enabled ? .on : .off
        enableItem?.isEnabled = store.settings.showMenuBarIcon
        permissionItem?.title = trusted ? "辅助功能：已授权" : "辅助功能：当前 App 未获授权…"
        statusItem?.button?.appearsDisabled = !store.settings.enabled
        if let menu = statusItem?.menu, menu.items.count > 2 {
            menu.items[2].title = hotKey?.registered == true ? "读取当前选区    ⌃⌥空格" : "读取当前选区（快捷键被占用）"
        }
    }

    private func refreshPermission(reinstallMonitors: Bool = false) {
        let current = AXIsProcessTrusted()
        let changed = current != trusted
        trusted = current
        if changed || reinstallMonitors {
            selectionMonitor.reinstallAfterPermissionChange()
        }
        // Keep the visible settings page synchronized even while System Settings
        // is frontmost. It must not wait for this window to become key again.
        settingsWindow.refreshPermission()
        updateMenu()
    }

    @objc private func toggleEnabled() { store.setEnabled(!store.settings.enabled) }

    @objc private func readSelection() {
        // Let the menu finish tracking before reading the source app's focused element.
        DispatchQueue.main.async { [weak self] in self?.selectionMonitor.requestSelection(explicit: true) }
    }

    @objc private func readClipboard() {
        // An explicit clipboard choice supersedes a pending automatic AX read.
        selectionMonitor.invalidate()
        guard store.settings.enabled else { showNotice("划词助手已暂停，请先启用。"); return }
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showNotice("剪贴板里没有文字。请先在原应用选中文字并按 ⌘C。"); return
        }
        // Reading is explicit. Never simulate Command-C or overwrite the user's clipboard.
        DispatchQueue.main.async { [weak self] in self?.offer(text: text, near: NSEvent.mouseLocation) }
    }

    @objc private func openSettings() {
        refreshPermission()
        selectionMonitor.invalidate()
        settingsWindow.show()
    }

    private func openSpeechSettings() {
        refreshPermission()
        selectionMonitor.invalidate()
        settingsWindow.showSpeechSettings()
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        PermissionRecoveryController.openSystemSettings()
        refreshPermission()
    }

    private func offer(text: String, near point: NSPoint) {
        guard store.settings.enabled, !panel.isPinned else { return }
        dismissPanel()
        selectedText = text
        selectedPoint = point
        panel.showActions(near: point)
    }

    private func run(mode: CompletionMode, bypassCache: Bool = false) {
        if mode == .ask { openChatFromSelection(); return }
        guard !selectedText.isEmpty else { return }
        task?.cancel()
        task = nil
        requestID = UUID()
        let token = requestID
        let text = selectedText
        // This decision depends only on the original selection, never on the
        // current target language or a previous model response.
        let dictionaryWord = TranslationRequest.sourceWord(text: text)
        selectedMode = mode
        translationOutput = ""
        translationReturnedModel = nil
        currentTranslation = nil
        let language = TranslationLanguage(rawValue: store.settings.translationTarget) ?? .simplifiedChinese
        panel.setTargetLanguage(language)
        panel.showResult(mode: mode)
        guard store.settings.enabled else { panel.showError("划词助手已暂停。"); return }
        task = Task { [weak self] in
            do {
                let sameLanguage = await Task.detached(priority: .userInitiated) {
                    TranslationPreflight.shouldSkipTranslation(text: text, target: language)
                }.value
                guard !Task.isCancelled, let self, self.requestID == token else { return }
                if sameLanguage {
                    // No Keychain read, API validation or network request is needed.
                    self.panel.showUnneededTranslation(original: text, language: language)
                    self.task = nil
                    return
                }
                let profile = self.store.profile(for: .translation)
                let configuration = try self.store.configuration(for: .translation)
                let cacheKey = TranslationCacheKey(original: text, targetLanguage: language.rawValue,
                    profileID: profile.id, endpoint: configuration.endpoint.absoluteString, model: configuration.model)
                if self.store.settings.cacheEnabled, !bypassCache,
                   var cached = self.translationCache.value(for: cacheKey) {
                    cached.createdAt = Date()
                    self.displayTranslation(cached)
                    self.completeTranslation(cached, note: "来自缓存 · 未调用 API")
                    self.task = nil
                    return
                }
                self.panel.setModelInfo(requested: configuration.model, returned: nil,
                                        endpointHost: configuration.endpoint.host ?? "")
                if let word = dictionaryWord {
                    self.panel.showDictionaryLoading(word: word)
                    let response = try await DictionaryService.lookup(
                        configuration: configuration, word: word, targetLanguage: language.instructionName,
                        onModel: { [weak self] model in
                            await MainActor.run {
                                guard let self, self.requestID == token else { return }
                                self.translationReturnedModel = model
                                self.panel.setModelInfo(requested: configuration.model, returned: model,
                                                        endpointHost: configuration.endpoint.host ?? "")
                            }
                        })
                    guard !Task.isCancelled, self.requestID == token else { return }
                    switch response {
                    case .entry(let entry):
                        self.panel.showDictionary(entry, word: word, target: language)
                        let record = self.makeTranslation(original: text, translated: entry.plainText(word: word),
                            dictionary: entry, target: language, configuration: configuration)
                        self.saveTranslation(record, cacheKey: cacheKey)
                    case .sameLanguage:
                        self.panel.showUnneededTranslation(original: text, language: language)
                    }
                    self.task = nil
                    return
                }
                try await APIClient.stream(configuration: configuration, mode: mode, text: text,
                                           targetLanguage: language.instructionName,
                                           onModel: { [weak self] model in
                    await MainActor.run {
                        guard let self = self, self.requestID == token else { return }
                        self.translationReturnedModel = model
                        self.panel.setModelInfo(requested: configuration.model, returned: model,
                                                endpointHost: configuration.endpoint.host ?? "")
                    }
                }, onDelta: { [weak self] delta in
                    await MainActor.run {
                        guard let self = self, self.requestID == token else { return }
                        self.translationOutput += delta
                        self.panel.append(delta)
                    }
                })
                guard !Task.isCancelled, self.requestID == token else { return }
                let unchanged = self.translationOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    == text.trimmingCharacters(in: .whitespacesAndNewlines)
                let record = self.makeTranslation(original: text, translated: self.translationOutput,
                    dictionary: nil, target: language, configuration: configuration)
                self.saveTranslation(record, cacheKey: cacheKey, note: unchanged
                    ? "返回内容与原文相同：可能是专有名称或已是目标语言。如需解释，可使用「问 AI」。"
                    : nil)
                self.task = nil
            } catch {
                guard !Task.isCancelled, let self = self, self.requestID == token else { return }
                self.panel.showError(error.localizedDescription)
                self.task = nil
            }
        }
    }

    private func configureTranslationCache() {
        translationCache.configure(maxEntries: store.settings.cacheMaxEntries,
                                   maxBytes: store.settings.cacheMaxMegabytes * 1_000_000)
        if !store.settings.cacheEnabled { translationCache.removeAll() }
    }

    private func makeTranslation(original: String, translated: String, dictionary: DictionaryEntry?,
                                 target: TranslationLanguage, configuration: APIConfiguration) -> SavedTranslation {
        SavedTranslation(original: original, targetLanguage: target.rawValue, translatedText: translated,
                         dictionary: dictionary, requestedModel: configuration.model,
                         returnedModel: translationReturnedModel, endpointHost: configuration.endpoint.host ?? "")
    }

    private func saveTranslation(_ record: SavedTranslation, cacheKey: TranslationCacheKey, note: String? = nil) {
        // Call only for complete, successful responses. Partial output and errors
        // must never suppress a later request with a misleading cache hit.
        if store.settings.cacheEnabled { translationCache.insert(record, for: cacheKey) }
        completeTranslation(record, note: note)
    }

    private func completeTranslation(_ record: SavedTranslation, note: String?) {
        currentTranslation = record
        var completionNote = note
        if store.settings.historyEnabled {
            translationHistory.add(record)
            if let error = translationHistory.lastError {
                completionNote = (note.map { $0 + "\n" } ?? "") + error
            }
        }
        panel.finish(note: completionNote)
        updateFavoriteButton()
    }

    private func displayTranslation(_ record: SavedTranslation) {
        translationOutput = record.translatedText
        translationReturnedModel = record.returnedModel
        let language = TranslationLanguage(rawValue: record.targetLanguage) ?? .simplifiedChinese
        if let dictionary = record.dictionary {
            let word = TranslationRequest.sourceWord(text: record.original) ?? record.original
            panel.showDictionary(dictionary, word: word, target: language)
        } else {
            panel.append(record.translatedText)
        }
        panel.setModelInfo(requested: record.requestedModel, returned: record.returnedModel,
                           endpointHost: record.endpointHost)
    }

    private func historyRecord(for record: SavedTranslation) -> SavedTranslation? {
        translationHistory.records.first {
            $0.original == record.original && $0.targetLanguage == record.targetLanguage
        }
    }

    private func updateFavoriteButton() {
        let saved = currentTranslation.flatMap { historyRecord(for: $0) }
        panel.setFavoriteState(available: currentTranslation != nil, isFavorite: saved?.isFavorite ?? false)
    }

    private func toggleCurrentFavorite() {
        guard let record = currentTranslation else { return }
        // Save the displayed result, even when automatic history is disabled
        // and an older translation of the same original already exists.
        let favorite = !(historyRecord(for: record)?.isFavorite ?? false)
        translationHistory.saveFavorite(record, isFavorite: favorite)
        updateFavoriteButton()
        if let error = translationHistory.lastError { panel.finish(note: error) }
        else {
            panel.finish(note: historyRecord(for: record)?.isFavorite == true ? "已收藏" : "已取消收藏")
        }
    }

    @objc private func openTranslationHistory() {
        selectionMonitor.invalidate()
        historyWindow.show()
    }

    private func showSavedTranslation(_ record: SavedTranslation) {
        selectionMonitor.invalidate()
        dismissPanel()
        selectedText = record.original
        selectedPoint = NSEvent.mouseLocation
        selectedMode = .translate
        let language = TranslationLanguage(rawValue: record.targetLanguage) ?? .simplifiedChinese
        store.setTranslationTarget(language)
        panel.setTargetLanguage(language)
        panel.showActions(near: selectedPoint ?? NSEvent.mouseLocation)
        panel.showResult(mode: .translate)
        displayTranslation(record)
        currentTranslation = record
        panel.finish(note: "历史记录 · 未调用 API")
        updateFavoriteButton()
    }

    private func stopGeneration() {
        task?.cancel()
        task = nil
        requestID = UUID()
        panel.stop()
    }

    private func dismissPanel() {
        task?.cancel()
        task = nil
        requestID = UUID()
        selectedText = ""
        selectedPoint = nil
        translationOutput = ""
        translationReturnedModel = nil
        currentTranslation = nil
        panel.hide()
    }

    private func openChatFromSelection() {
        // Capture text and its original location before invalidation clears both.
        let question = selectedText
        let point = selectedPoint
        selectionMonitor.invalidate()
        chatWindow.show(near: point)
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            renderChat(errorOverride: "未读到所选文字，请重新划词后点击「问 AI」。")
            return
        }
        sendChat(question: question, fromSelection: true)
    }

    @objc private func openChatWindow() {
        selectionMonitor.invalidate()
        chatWindow.show()
        renderChat()
    }

    private func renderChat(errorOverride: String? = nil) {
        let profile = store.profile(for: .chat)
        chatWindow.setModelInfo(requested: profile.model, returned: chatReturnedModel,
                                endpointHost: URL(string: profile.baseURL)?.host ?? "未配置")
        chatWindow.render(messages: conversation.displayMessages,
                          pendingUser: conversation.pendingUser, pendingAnswer: conversation.pendingAnswer,
                          status: errorOverride ?? conversation.status,
                          isError: errorOverride != nil || conversation.isError,
                          isGenerating: conversation.isGenerating, canRetry: conversation.canRetry)
    }

    private func sendChat(question: String, fromSelection: Bool = false) {
        guard fromSelection || !conversation.isGenerating else { return }
        let configuration: APIConfiguration
        do {
            configuration = try store.configuration(for: .chat)
            if fromSelection {
                // Accept the new question before replacing the old conversation;
                // invalid input must leave its history and live request intact.
                try conversation.beginSelection(question: question)
                chatWindow.setSelectionContext(question)
            } else {
                try conversation.begin(question: question)
            }
        } catch {
            if fromSelection {
                chatWindow.appendDraft(question)
                renderChat(errorOverride: "所选文字未能发送，已保留在输入框。" + error.localizedDescription)
            } else {
                renderChat(errorOverride: error.localizedDescription)
            }
            return
        }
        // Sending a selection must not send or erase an unfinished follow-up draft.
        if !fromSelection { chatWindow.resetDraft() }
        startChatRequest(configuration: configuration)
    }

    private func retryChat() {
        guard !conversation.isGenerating, conversation.canRetry else { return }
        do {
            let configuration = try store.configuration(for: .chat)
            try conversation.retry()
            startChatRequest(configuration: configuration)
        } catch { renderChat(errorOverride: error.localizedDescription) }
    }

    private func startChatRequest(configuration: APIConfiguration) {
        chatTask?.cancel()
        chatRequestID = UUID()
        let token = chatRequestID
        chatReturnedModel = nil
        let messages: [ChatMessage]
        do { messages = try conversation.requestMessages() }
        catch { conversation.fail(error.localizedDescription); renderChat(); return }
        renderChat()
        chatTask = Task { [weak self] in
            do {
                try await APIClient.stream(configuration: configuration, messages: messages,
                                           onModel: { [weak self] model in
                    await MainActor.run {
                        guard let self = self, self.chatRequestID == token else { return }
                        self.chatReturnedModel = model
                        self.renderChat()
                    }
                }, onDelta: { [weak self] delta in
                    await MainActor.run {
                        guard let self = self, self.chatRequestID == token else { return }
                        self.conversation.append(delta)
                        self.scheduleChatRender()
                    }
                })
                guard !Task.isCancelled, let self = self, self.chatRequestID == token else { return }
                self.conversation.complete()
                self.chatTask = nil
                self.renderChat()
            } catch {
                guard !Task.isCancelled, let self = self, self.chatRequestID == token else { return }
                self.conversation.fail(error.localizedDescription)
                self.chatTask = nil
                self.renderChat()
            }
        }
    }

    private func stopChatGeneration() {
        chatTask?.cancel()
        chatTask = nil
        chatRequestID = UUID()
        conversation.cancel()
        renderChat()
    }

    private func scheduleChatRender() {
        guard !chatRenderScheduled else { return }
        chatRenderScheduled = true
        let token = chatRequestID
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            guard let self = self else { return }
            self.chatRenderScheduled = false
            guard self.chatRequestID == token else { return }
            self.renderChat()
        }
    }

    private func showNotice(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "划词助手"
        alert.informativeText = message
        alert.addButton(withTitle: "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
