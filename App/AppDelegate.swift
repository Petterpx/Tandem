import AppKit

/// 退出前先收尾所有录屏并停掉所有会话，清理 adb forward 与设备上的 scrcpy-server。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var services: AppServices?

    /// 以 `--background` 拉起：只留菜单栏图标，不显示 Dock 图标、不抢焦点；用户打开工作台时切回 .regular。
    func applicationWillFinishLaunching(_ notification: Notification) {
        if AppPolicy.isBackgroundLaunch(arguments: ProcessInfo.processInfo.arguments) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    /// 点 Dock 图标：工作台不可见（已关闭或最小化）就重新打开，不管弹出窗口是否可见。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // SwiftUI 把 Window 场景的 id（TandemApp 里的 "workspace"）用作 NSWindow.identifier
        let workspace = sender.windows.first { $0.identifier?.rawValue == "workspace" }
        if let workspace, workspace.isMiniaturized {
            workspace.deminiaturize(nil)
        } else if workspace?.isVisible != true {
            Self.services?.model.requestOpenWorkspace?()
        } else {
            return true
        }
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
