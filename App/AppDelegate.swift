import AppKit

/// 退出前先收尾所有录屏并停掉所有会话，清理 adb forward 与设备上的 scrcpy-server。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var services: AppServices?

    /// 点 Dock 图标且没有可见窗口时重新打开工作台。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        Self.services?.model.requestOpenWorkspace?()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let services = Self.services else { return .terminateNow }
        // 录屏收尾与停止会话都完成后才退出；最多等 4 秒，之后无论如何都允许退出。
        var replied = false
        let finish: @MainActor () -> Void = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await services.shutdown()
            finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            finish()
        }
        return .terminateLater
    }
}
