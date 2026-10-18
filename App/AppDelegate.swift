import AppKit

/// 退出前先停掉所有会话，清理 adb forward 与设备上的 scrcpy-server。
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        // 并发停止所有会话，最多等 4 秒，之后无论如何都允许退出。
        var replied = false
        let finish: @MainActor () -> Void = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        Task { @MainActor in
            await model.stopAll()
            finish()
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            finish()
        }
        return .terminateLater
    }
}
