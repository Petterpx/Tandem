import Foundation
import DeviceCore

/// 绑定在某个 adb serial 上的设备操作。
public struct AndroidActions: DeviceActions {
    private let serial: String
    private let adb: AdbClient

    public init(serial: String, adb: AdbClient) {
        self.serial = serial
        self.adb = adb
    }

    public func screenshot() async throws -> Data {
        let data = try await adb.execOut(serial, ["screencap", "-p"])
        // PNG 签名；设备锁屏或 screencap 报错时 stdout 可能是文本。
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.starts(with: signature) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "截图数据无效", suggestion: "请确认设备已解锁后重试")
        }
        return data
    }

    public func uiTree() async throws -> UITree {
        let path = "/data/local/tmp/tandem_ui.xml"
        var dumped = false
        for _ in 0..<2 {
            let out = try await adb.shell(serial, "uiautomator dump \(path)", timeout: .seconds(15))
            if out.contains("dumped to") { dumped = true; break }
        }
        guard dumped else {
            throw DeviceError(
                code: .CONNECTION_FAILED,
                message: "读取界面结构失败",
                suggestion: "界面可能正在动画或页面禁止读取，请稍后重试或改用截图"
            )
        }
        let xml = try await adb.execOut(serial, ["cat", path])
        return try UIHierarchyParser.parse(xml, screen: await displaySize(rotation: UIHierarchyParser.rotation(in: xml)))
    }

    /// UI 树坐标须与截图同一空间（整块显示器，含导航栏），而不是前台窗口的 bounds。
    private func displaySize(rotation: Int?) async -> CGSize? {
        if let out = try? await adb.shell(serial, "dumpsys window displays", timeout: .seconds(10)),
           let size = UIHierarchyParser.displaySize(dumpsys: out) {
            return size
        }
        if let out = try? await adb.shell(serial, "wm size") {
            return UIHierarchyParser.displaySize(wmSize: out, rotation: rotation)
        }
        return nil
    }
}
