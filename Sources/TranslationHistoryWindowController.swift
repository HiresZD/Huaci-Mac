import AppKit
import UniformTypeIdentifiers

private final class TranslationHistoryCell: NSTableCellView {
    let titleLabel = NSTextField(labelWithString: "")
    let subtitleLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4)
        ])
        textField = titleLabel
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Browses saved results only. Opening, copying and exporting never query a model.
/// AppDelegate owns the store's onChange callback and calls reload() as needed.
@MainActor
final class TranslationHistoryWindowController: NSWindowController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    var onOpen: ((SavedTranslation) -> Void)?

    private let store: TranslationHistoryStore
    private let filterControl = NSSegmentedControl(labels: ["最近", "收藏"], trackingMode: .selectOne,
                                                   target: nil, action: nil)
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let detail = NSTextView(frame: NSRect(x: 0, y: 0, width: 430, height: 350))
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let openButton = NSButton(title: "查看结果", target: nil, action: nil)
    private let copyButton = NSButton(title: "复制译文", target: nil, action: nil)
    private let favoriteButton = NSButton(title: "收藏", target: nil, action: nil)
    private let deleteButton = NSButton(title: "删除所选", target: nil, action: nil)
    private let clearButton = NSButton(title: "清空历史", target: nil, action: nil)
    private let exportButton = NSButton(title: "导出当前列表", target: nil, action: nil)
    private var visibleRecords: [SavedTranslation] = []
    private var exporting = false
    private var wasPresented = false

    init(store: TranslationHistoryStore) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 570),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "划词助手 · 翻译历史与收藏"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        buildInterface()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        reload()
        guard let window else { return }
        if !wasPresented { window.center(); wasPresented = true }
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func reload() {
        let selectedID = selectedRecord?.id
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let favoritesOnly = filterControl.selectedSegment == 1
        visibleRecords = store.records.filter { record in
            (!favoritesOnly || record.isFavorite) &&
                (query.isEmpty || record.original.localizedStandardContains(query) ||
                 record.translatedText.localizedStandardContains(query))
        }.sorted { $0.createdAt > $1.createdAt }
        table.reloadData()
        if let selectedID, let row = visibleRecords.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else if !visibleRecords.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        renderSelectedRecord()
        updateStatus()
    }

    private var selectedRecord: SavedTranslation? {
        let row = table.selectedRow
        guard visibleRecords.indices.contains(row) else { return nil }
        return visibleRecords[row]
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleRecords.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard visibleRecords.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("TranslationHistoryRecord")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TranslationHistoryCell
            ?? TranslationHistoryCell(frame: .zero)
        cell.identifier = identifier
        let record = visibleRecords[row]
        let preview = record.original.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        cell.titleLabel.stringValue = (record.isFavorite ? "★ " : "") + String(preview.prefix(160))
        cell.titleLabel.toolTip = record.original
        let date = DateFormatter.localizedString(from: record.createdAt, dateStyle: .short, timeStyle: .short)
        cell.subtitleLabel.stringValue = "\(languageTitle(record)) · \(date)"
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { renderSelectedRecord() }

    func controlTextDidChange(_ obj: Notification) { reload() }

    @objc private func filterChanged(_ sender: Any?) { reload() }

    private func renderSelectedRecord() {
        guard let record = selectedRecord else {
            detail.string = visibleRecords.isEmpty
                ? (searchField.stringValue.isEmpty ? "暂无记录。\n\n可以在翻译结果中收藏，或在设置里开启保存翻译历史。" : "没有找到匹配的记录。")
                : "请选择一条记录。"
            updateButtons()
            return
        }
        let content = NSMutableAttributedString(string: "")
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 7
        paragraph.lineSpacing = 3
        func append(_ text: String, heading: Bool = false) {
            content.append(NSAttributedString(string: text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: heading ? 12 : 15, weight: heading ? .semibold : .regular),
                .foregroundColor: heading ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
        }
        let date = DateFormatter.localizedString(from: record.createdAt, dateStyle: .medium, timeStyle: .medium)
        append("\(languageTitle(record)) · \(date)" + (record.isFavorite ? " · 已收藏" : ""), heading: true)
        append("原文", heading: true)
        append(record.original)
        append(record.dictionary == nil ? "译文" : "词典解释", heading: true)
        append(record.translatedText)
        detail.textStorage?.setAttributedString(content)
        detail.setSelectedRange(NSRange(location: 0, length: 0))
        detail.scrollRangeToVisible(NSRange(location: 0, length: 0))
        updateButtons()
    }

    private func languageTitle(_ record: SavedTranslation) -> String {
        TranslationLanguage(rawValue: record.targetLanguage)?.title ?? "未知语言"
    }

    private func updateButtons() {
        let record = selectedRecord
        openButton.isEnabled = record != nil
        copyButton.isEnabled = record != nil
        favoriteButton.isEnabled = record != nil
        favoriteButton.title = record?.isFavorite == true ? "取消收藏" : "收藏"
        deleteButton.isEnabled = record != nil
        clearButton.isEnabled = store.records.contains(where: { !$0.isFavorite })
        exportButton.isEnabled = !visibleRecords.isEmpty && !exporting
    }

    private func updateStatus(message: String? = nil) {
        statusLabel.stringValue = store.lastError ?? message ?? "当前列表 \(visibleRecords.count) 条 · 保存在本机；清空历史会保留收藏。"
        statusLabel.textColor = store.lastError == nil ? .secondaryLabelColor : .systemRed
        statusLabel.toolTip = statusLabel.stringValue
        updateButtons()
    }

    @objc private func openSelected(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        onOpen?(record)
    }

    @objc private func copySelected(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.translatedText, forType: .string)
        updateStatus(message: "已复制译文。")
    }

    @objc private func toggleSelectedFavorite(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        store.toggleFavorite(id: record.id)
        reload()
    }

    @objc private func deleteSelected(_ sender: Any?) {
        guard let record = selectedRecord else { return }
        if record.isFavorite, let window {
            let alert = NSAlert()
            alert.messageText = "删除这条收藏？"
            alert.informativeText = "将同时删除原文和已保存的翻译结果，此操作无法撤销。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "删除")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else { return }
                self.store.remove(id: record.id)
                self.reload()
            }
        } else {
            store.remove(id: record.id)
            reload()
        }
    }

    @objc private func clearHistory(_ sender: Any?) {
        guard let window, store.records.contains(where: { !$0.isFavorite }) else { return }
        let alert = NSAlert()
        alert.messageText = "清空翻译历史？"
        alert.informativeText = "将删除所有未收藏的记录，包括当前搜索或筛选未显示的记录。收藏会保留，此操作无法撤销。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "清空历史")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            self.store.clearHistory()
            self.reload()
        }
    }

    @objc private func exportVisible(_ sender: Any?) {
        guard let window, !exporting, !visibleRecords.isEmpty else { return }
        // Freeze the filtered list before opening the save panel. New translations
        // and filter changes cannot change what this export contains.
        let snapshot = visibleRecords
        let exportedAt = Date()
        let markdown = Self.markdown(snapshot, exportedAt: exportedAt)
        let savePanel = NSSavePanel()
        savePanel.title = "导出翻译记录"
        savePanel.prompt = "导出"
        savePanel.message = "导出点击时当前列表的 \(snapshot.count) 条记录；已应用「最近 / 收藏」和搜索筛选。"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        savePanel.nameFieldStringValue = "Huaci-Translations-\(formatter.string(from: exportedAt)).md"
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.allowsOtherFileTypes = false
        savePanel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText)
            ?? UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)]
        exporting = true
        updateButtons()
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            defer { self.exporting = false; self.updateButtons() }
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try markdown.write(to: url, atomically: true, encoding: .utf8)
                self.updateStatus(message: "已导出 \(snapshot.count) 条记录。")
            } catch {
                guard let window = self.window else { return }
                let alert = NSAlert()
                alert.messageText = "导出失败"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "知道了")
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    private static func markdown(_ records: [SavedTranslation], exportedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        var sections = ["# 划词助手翻译记录", "导出时间：\(formatter.string(from: exportedAt))", "记录数：\(records.count)"]
        for (index, record) in records.enumerated() {
            let target = TranslationLanguage(rawValue: record.targetLanguage)?.title ?? "未知语言"
            sections.append("## 第 \(index + 1) 条\n\n目标语言：\(target)\n\n时间：\(formatter.string(from: record.createdAt))\n\n收藏：\(record.isFavorite ? "是" : "否")")
            sections.append("### 原文\n\n" + literalBlock(record.original))
            sections.append("### \(record.dictionary == nil ? "译文" : "词典解释")\n\n" + literalBlock(record.translatedText))
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func literalBlock(_ text: String) -> String {
        var longest = 0
        var run = 0
        for byte in text.utf8 {
            if byte == 0x60 { run += 1; longest = max(longest, run) }
            else { run = 0 }
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "text\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        filterControl.selectedSegment = 0
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))
        searchField.placeholderString = "搜索原文或译文"
        searchField.delegate = self
        searchField.setAccessibilityLabel("搜索原文或译文")
        let header = NSStackView(views: [filterControl, searchField])
        header.orientation = .horizontal
        header.spacing = 12
        header.alignment = .centerY
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel("翻译记录列表")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.borderType = .bezelBorder

        detail.isEditable = false
        detail.isSelectable = true
        detail.isRichText = false
        detail.isAutomaticLinkDetectionEnabled = false
        detail.isAutomaticDataDetectionEnabled = false
        detail.font = .systemFont(ofSize: 15)
        detail.textColor = .labelColor
        detail.backgroundColor = .textBackgroundColor
        detail.textContainerInset = NSSize(width: 12, height: 12)
        detail.isVerticallyResizable = true
        detail.isHorizontallyResizable = false
        detail.autoresizingMask = [.width]
        detail.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        detail.textContainer?.widthTracksTextView = true
        detail.textContainer?.containerSize = NSSize(width: 430, height: CGFloat.greatestFiniteMagnitude)
        detail.setAccessibilityLabel("已保存的原文和翻译结果")
        let detailScroll = NSScrollView()
        detailScroll.documentView = detail
        detailScroll.hasVerticalScroller = true
        detailScroll.borderType = .bezelBorder

        let body = NSStackView(views: [listScroll, detailScroll])
        body.orientation = .horizontal
        body.spacing = 12
        body.alignment = .top
        let actions = NSStackView(views: [openButton, copyButton, favoriteButton, deleteButton])
        actions.orientation = .horizontal
        actions.spacing = 8
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [clearButton, spacer, exportButton])
        bottom.orientation = .horizontal
        bottom.spacing = 8
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isSelectable = true
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let bindings: [(NSButton, Selector)] = [
            (openButton, #selector(openSelected(_:))), (copyButton, #selector(copySelected(_:))),
            (favoriteButton, #selector(toggleSelectedFavorite(_:))), (deleteButton, #selector(deleteSelected(_:))),
            (clearButton, #selector(clearHistory(_:))), (exportButton, #selector(exportVisible(_:)))
        ]
        for (button, action) in bindings {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
        }
        clearButton.toolTip = "清除所有未收藏的历史，收藏会保留。"
        exportButton.toolTip = "将当前筛选和搜索得到的列表导出为 Markdown 文件。"
        openButton.toolTip = "在翻译窗口中查看已保存的结果，不重新请求 API。"
        for view in [header, body, actions, statusLabel, bottom] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        detailScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            body.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            body.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            listScroll.widthAnchor.constraint(equalToConstant: 250),
            body.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
            listScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            detailScroll.heightAnchor.constraint(equalTo: body.heightAnchor),
            detailScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300),
            actions.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 10),
            actions.leadingAnchor.constraint(equalTo: detailScroll.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bottom.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            bottom.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }
}
