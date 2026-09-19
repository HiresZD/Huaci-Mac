import AppKit
import ApplicationServices

/// TCC is authoritative. Recovery never fabricates a granted state or edits its database.
@MainActor
final class PermissionRecoveryController {
    private static let bundleID = "com.local.huaci-assistant"
    private let onRefresh: () -> Void
    private var isResetting = false

    init(onRefresh: @escaping () -> Void) { self.onRefresh = onRefresh }

    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func show() {
        guard !isResetting else {
            showResult("正在重置 Huaci 的授权", message: "正在等待系统工具返回，最长约 15 秒。请稍候，无需重复重置。", revealApp: false)
            return
        }
        onRefresh()
        let app = Bundle.main.bundleURL
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).count
        let extra = copies > 1 ? "\n检测到 \(copies) 个运行副本，请先从各自菜单栏退出多余副本。" : ""
        let granted = AXIsProcessTrusted()
        let alert = NSAlert()
        alert.messageText = granted ? "当前 App 已获得辅助功能权限" : "系统已开启，但 App 仍无法读取？"
        alert.informativeText = """
        当前版本：\(version)
        当前运行位置：\(app.path)\(extra)

        系统列表可能保留着旧版或另一位置的 Huaci。点击「定位当前 App」，在系统权限列表中移除旧 Huaci，再用 + 添加 Finder 中选中的这份 App，并开启开关。该页面在你的系统中可能叫「设备控制和数据访问」。

        若仍无效，可退出后重新打开；也可只重置 Huaci 的辅助功能授权，再重新添加。
        """
        alert.addButton(withTitle: "定位当前 App")
        alert.addButton(withTitle: "重置本 App 授权…")
        alert.addButton(withTitle: "退出后重新打开…")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Self.openSystemSettings()
            NSWorkspace.shared.activateFileViewerSelecting([app])
        case .alertSecondButtonReturn: confirmReset()
        case .alertThirdButtonReturn: confirmQuit()
        default: break
        }
    }

    private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "退出当前划词助手？"
        alert.informativeText = "会停止请求并清空内存中的对话，API 配置和密钥会保留。Finder 将定位当前 App；退出后请双击它重新打开。"
        alert.addButton(withTitle: "定位并退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        NSApp.terminate(nil)
    }

    private func confirmReset() {
        // Never broaden this to all apps/services, even if the bundle was renamed.
        guard Bundle.main.bundleIdentifier == Self.bundleID else { return }
        let alert = NSAlert()
        alert.messageText = "重置 Huaci 的辅助功能授权？"
        alert.informativeText = "只清除 Huaci 的这项授权记录，不影响其他 App，也不删除 API 配置或密钥。重置后必须由你在系统设置里重新添加并开启当前 App；重置本身不会授予权限。"
        alert.addButton(withTitle: "重置 Huaci 授权")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        isResetting = true
        Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { () async throws -> Int32 in
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
                    process.arguments = ["reset", "Accessibility", "com.local.huaci-assistant"]
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    defer {
                        if process.isRunning { process.terminate() }
                    }
                    let deadline = ProcessInfo.processInfo.systemUptime + 15
                    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning {
                        throw AssistantAPIError("系统权限工具在 15 秒内没有返回。请在系统设置中手动移除旧 Huaci，再添加当前 App。")
                    }
                    process.waitUntilExit()
                    return process.terminationStatus
                }.value
                guard let self = self else { return }
                self.isResetting = false
                self.onRefresh()
                if result == 0 {
                    self.showResult("已清除旧授权记录", message: "接下来在系统设置中用 + 添加 Finder 选中的这份 Huaci，并开启开关。回到 App 点击「重新检测」；如果仍未生效，在「修复授权」中退出后重新打开。", revealApp: true)
                } else {
                    self.showResult("系统未完成重置", message: "系统工具退出码：\(result)。可在系统权限列表中手动移除旧 Huaci，再添加当前 App。", revealApp: true)
                }
            } catch {
                guard let self = self else { return }
                self.isResetting = false
                self.showResult("无法启动权限重置", message: error.localizedDescription, revealApp: false)
            }
        }
    }

    private func showResult(_ title: String, message: String, revealApp: Bool) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: revealApp ? "打开系统设置并定位 App" : "知道了")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        if revealApp {
            Self.openSystemSettings()
            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
        }
    }
}
