import DeviceCore
import Foundation

extension AndroidActions {
    /// 先推到设备临时路径再 `pm install`；返回 Mac 上读到的包名（读不到为 nil，安装照常进行）。
    /// 无论成败（含取消）都会删除临时文件。
    public func install(apk: URL, progress: @escaping ProgressHandler) async throws -> String? {
        try await install(apk: apk, tempID: UUID(), progress: progress)
    }

    func install(apk: URL, tempID: UUID, progress: @escaping ProgressHandler) async throws -> String? {
        let package = await ApkManifest.packageName(apk: apk, runner: adb.runner)
        let temp = AndroidCommands.Install.tempPath(tempID)
        do {
            try await push(apk, to: temp, progress: progress)
            let out = try await shellChecked(
                AndroidCommands.Install.installCommand(temp), timeout: .seconds(120), detectUnsupported: false).output
            guard out.contains("Success") else {
                let raw = out.trimmingCharacters(in: .whitespacesAndNewlines)
                throw DeviceError(
                    code: .CONNECTION_FAILED, message: "安装失败：\(raw)",
                    suggestion: AndroidCommands.Install.failureAdvice(raw))
            }
        } catch {
            await removeTemp(temp)
            throw error
        }
        await removeTemp(temp)
        return package
    }

    /// 通知媒体库扫描这些文件（推送的图片、视频随即出现在相册）。
    public func mediaScan(_ paths: [String]) async throws {
        for path in paths {
            let path = try DevicePath.validate(path)
            _ = try await shellChecked(AndroidCommands.Install.scanCommand(path))
        }
    }

    /// 清理在非结构化任务里跑，不受当前任务已取消的影响；尽力而为。
    private func removeTemp(_ path: String) async {
        let (adb, serial) = (adb, serial)
        await Task { _ = try? await adb.run(["shell", "rm -f \(ShellQuote.quote(path))"], serial: serial) }.value
    }
}
