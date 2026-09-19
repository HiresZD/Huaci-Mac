import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SelectionMonitor {
    var onSelection: ((String, NSPoint) -> Void)?
    var onDismiss: (() -> Void)?
    var onEscape: (() -> Void)?
    var onUnavailable: ((String) -> Void)?
    var enabled = true
    var popupAfterCopy = false

    private var mouseMonitor: Any?
    private var keyMonitor: Any?
    private var localMonitor: Any?
    private var workspaceObserver: NSObjectProtocol?
    private var generation = 0
    private var mouseDownPoint: NSPoint?
    private var dragged = false
    private var lastExternalApp: NSRunningApplication?
    private var preparedPIDs = Set<pid_t>()
    private var copyTask: Task<Void, Never>?
    private struct CopyBaseline {
        let changeCount: Int
        let pid: pid_t
        let time: TimeInterval
    }
    private var copyBaseline: CopyBaseline?
    private let readerQueue = DispatchQueue(label: "com.local.huaci.selection", qos: .userInitiated)

    func start() {
        guard mouseMonitor == nil else { return }
        rememberFrontmostApp()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            self?.handleMouse(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.invalidate()
                self?.onEscape?()
            }
            return event
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.rememberFrontmostApp()
                self?.invalidate()
            }
        }
        refreshKeyboardMonitor()
    }

    // Reinstall after the user grants Accessibility permission; a monitor created before
    // authorization may not receive global keyboard events until it is registered again.
    func refreshKeyboardMonitor() {
        if let existing = keyMonitor { NSEvent.removeMonitor(existing); keyMonitor = nil }
        guard AXIsProcessTrusted() else { return }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self = self else { return }
            if event.type == .flagsChanged {
                self.prepareCopyBaseline(event)
            } else if event.type == .keyDown {
                let baseline = self.copyBaseline
                self.invalidate()
                // Escape is an explicit close, including when another app has
                // focus and the result window is pinned against ambient events.
                if event.keyCode == 53 {
                    self.onEscape?()
                    return
                }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                if modifiers.contains(.command),
                   modifiers.intersection([.control, .option, .shift]).isEmpty,
                   event.charactersIgnoringModifiers?.lowercased() == "c", !event.isARepeat {
                    self.waitForExplicitCopy(baseline: baseline)
                }
            } else {
                // Also covers Command-A followed by Command-C while Command is held.
                self.prepareCopyBaseline(event)
                if (event.modifierFlags.contains(.shift) && [123, 124, 125, 126, 115, 119].contains(event.keyCode)) ||
                        (event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers?.lowercased() == "a") {
                    self.requestSelection(explicit: false)
                }
            }
        }
    }

    func reinstallAfterPermissionChange() {
        stop()
        preparedPIDs.removeAll()
        mouseDownPoint = nil
        dragged = false
        start()
    }

    func stop() {
        for monitor in [mouseMonitor, keyMonitor, localMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
        mouseMonitor = nil
        keyMonitor = nil
        localMonitor = nil
        if let observer = workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObserver = nil
        invalidate()
    }

    func invalidate() {
        generation += 1
        copyTask?.cancel()
        copyTask = nil
        copyBaseline = nil
        onDismiss?()
    }

    private func prepareCopyBaseline(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard enabled, popupAfterCopy, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              modifiers.contains(.command), modifiers.intersection([.control, .option, .shift]).isEmpty,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            copyBaseline = nil
            return
        }
        // A global key monitor may run after the target app has already copied.
        // Snapshot only the change counter before C, not any clipboard contents.
        copyBaseline = CopyBaseline(changeCount: NSPasteboard.general.changeCount,
                                    pid: app.processIdentifier,
                                    time: ProcessInfo.processInfo.systemUptime)
    }

    /// This path requires the user to enable compatibility mode and physically
    /// press Command-C in another app. It never generates keyboard events or
    /// writes/restores the clipboard, and never accepts an unchanged clipboard.
    private func waitForExplicitCopy(baseline: CopyBaseline?) {
        guard enabled, popupAfterCopy, AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        let token = generation
        let initialChangeCount: Int
        if let baseline, baseline.pid == pid,
           (0...2).contains(ProcessInfo.processInfo.systemUptime - baseline.time) {
            initialChangeCount = baseline.changeCount
        } else {
            initialChangeCount = NSPasteboard.general.changeCount
        }
        let point = NSEvent.mouseLocation
        copyTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.generation == token { self.copyTask = nil }
            }
            for attempt in 0...12 {
                if attempt > 0 {
                    do { try await Task.sleep(nanoseconds: 80_000_000) }
                    catch { return }
                }
                guard !Task.isCancelled, let self,
                      self.generation == token, self.enabled, self.popupAfterCopy,
                      AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                let pasteboard = NSPasteboard.general
                let changed = pasteboard.changeCount
                guard changed != initialChangeCount else { continue }
                // Explicitly concealed/transient data and Finder file copies
                // are not text selections for an automatic action menu.
                let excluded: [NSPasteboard.PasteboardType] = [
                    .fileURL,
                    NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
                    NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
                    NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
                ]
                guard pasteboard.availableType(from: excluded) == nil,
                      let text = pasteboard.string(forType: .string),
                      pasteboard.changeCount == changed,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      text.utf16.count <= SelectionTextRange.maximumSelectionUTF16Length else { return }
                self.onSelection?(text, point)
                return
            }
        }
    }

    private func rememberFrontmostApp() {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApp = application
        }
    }

    private func handleMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            invalidate()
            rememberFrontmostApp()
            mouseDownPoint = NSEvent.mouseLocation
            dragged = false
        case .leftMouseDragged:
            if let start = mouseDownPoint {
                let now = NSEvent.mouseLocation
                dragged = dragged || hypot(now.x - start.x, now.y - start.y) > 3
            }
        case .leftMouseUp:
            let shouldRead = dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift)
            mouseDownPoint = nil
            dragged = false
            if shouldRead { requestSelection(explicit: false, fromPointer: true) }
        case .rightMouseDown, .otherMouseDown, .scrollWheel:
            invalidate()
        default:
            break
        }
    }

    func requestSelection(explicit: Bool, fromPointer: Bool = false) {
        guard enabled else {
            if explicit { onUnavailable?("划词助手已暂停，请从菜单栏重新启用。") }
            return
        }
        guard AXIsProcessTrusted() else {
            if explicit { onUnavailable?("系统尚未向当前运行的 App 授予辅助功能权限。若系统开关已开启，请在划词助手设置中点击「重新检测」或「修复授权」，检查旧版记录和当前 App 位置。") }
            return
        }
        rememberFrontmostApp()
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            if explicit { onUnavailable?("请先在其他应用中选中文字，再使用全局快捷键读取。") }
            return
        }
        guard let application = lastExternalApp, !application.isTerminated else { return }
        copyTask?.cancel()
        copyTask = nil
        generation += 1
        let requestID = generation
        let point = NSEvent.mouseLocation
        // AX hit-testing uses Quartz coordinates, whose origin is at the top
        // left of the primary screen; AppKit mouse coordinates grow upwards.
        let accessibilityPoint = (fromPointer ? NSScreen.screens.first : nil).map {
            CGPoint(x: point.x, y: $0.frame.maxY - point.y)
        }
        let pid = application.processIdentifier
        let bundleID = application.bundleIdentifier ?? ""
        let chromium = ["com.google.Chrome", "org.chromium.Chromium", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "com.electron.", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord", "com.notion.id"].contains { bundleID.hasPrefix($0) }
        let prepare = chromium && !preparedPIDs.contains(pid)

        readAfterDelay(pid: pid, requestID: requestID, point: point, accessibilityPoint: accessibilityPoint,
                       explicit: explicit, prepare: prepare, retryIfEmpty: true,
                       retryDelay: prepare ? 2.2 : 0.24, delay: 0.14)
    }

    private func readAfterDelay(pid: pid_t, requestID: Int, point: NSPoint, accessibilityPoint: CGPoint?,
                                explicit: Bool, prepare: Bool, retryIfEmpty: Bool,
                                retryDelay: Double, delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, self.generation == requestID, self.enabled,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            // Do not mark a process until its preparation is actually queued. A cancelled
            // debounce must not permanently suppress accessibility initialization.
            let shouldPrepare = prepare && self.preparedPIDs.insert(pid).inserted
            self.readerQueue.async { [weak self] in
                let result = AccessibilityReader.read(pid: pid, point: accessibilityPoint, enableChromium: shouldPrepare)
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.generation == requestID, self.enabled, AXIsProcessTrusted(),
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    if let text = result.text {
                        self.onSelection?(text, point)
                    } else if retryIfEmpty && !result.secure {
                        // Some readers update their selection after mouse-up;
                        // Chromium's initial accessibility activation takes longer.
                        self.readAfterDelay(pid: pid, requestID: requestID, point: point, accessibilityPoint: accessibilityPoint,
                                            explicit: explicit, prepare: false, retryIfEmpty: false,
                                            retryDelay: retryDelay, delay: retryDelay)
                    } else if explicit {
                        self.onUnavailable?(result.secure
                            ? "密码输入框不支持取词。"
                            : "没有读到这个控件的选中文字。可在设置中开启「复制后显示划词选项」，选中后按 ⌘C；或复制后从菜单栏选择「使用剪贴板文字」。")
                    }
                }
            }
        }
    }
}
