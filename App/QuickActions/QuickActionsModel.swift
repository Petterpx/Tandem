import DeviceCore
import Foundation
import Observation

/// 「应用」分段的目标：前台 App，或某个已固定的包名。
enum AppTarget: Hashable {
    case foreground, pinned(String)
}

/// 「快捷操作」面板的状态，全部按设备 id 保存（spec §3.2）。
/// 每次读取的结果写入发起时的 id 下；视图只读当前选中 id 的条目，上一台设备晚返回的读取不会覆盖当前面板。
@MainActor @Observable
final class QuickActionsModel {
    let commands: DeviceCommands
    let store: QuickActionsStore

    private(set) var network: [String: Result<NetworkState, DeviceError>] = [:]
    private(set) var foreground: [String: Result<AppInfo, DeviceError>] = [:]
    private(set) var devOptions: [String: Result<DevOptions, DeviceError>] = [:]
    private(set) var system: [String: Result<SystemSettings, DeviceError>] = [:]
    private(set) var target: [String: AppTarget] = [:]
    /// 正在修改的分段，键为 `"<id>.<section>"`。
    private(set) var busy: Set<String> = []
    /// 自定义命令最近一次的输出。
    var lastOutput: [UUID: ShellResult] = [:]

    init(commands: DeviceCommands, store: QuickActionsStore) {
        self.commands = commands
        self.store = store
    }

    // MARK: 目标 App

    /// 当前目标；固定的包名被移除后回到「前台 App」。
    func currentTarget(_ id: String) -> AppTarget {
        if case .pinned(let p) = target[id], store.pinnedPackages.contains(p) { return .pinned(p) }
        return .foreground
    }

    /// 目标包名：前台 App 只在读取成功时有值，读不到时为 nil，不沿用旧值。
    func targetPackage(_ id: String) -> String? {
        switch currentTarget(id) {
        case .foreground: try? foreground[id]?.get().package
        case .pinned(let p): p
        }
    }

    /// 切换目标；系统分段的 App 语言随目标变化，重新读取。
    func setTarget(_ id: String, _ t: AppTarget) async {
        target[id] = t
        await refresh(id, section: .system)
    }

    /// 把前台 App 加入固定列表（所有设备共用）。
    func pinForeground(_ id: String) {
        guard case .success(let app)? = foreground[id], !app.package.isEmpty else { return }
        store.pin(app.package)
    }

    func unpin(_ package: String) {
        store.unpin(package)
        for (id, t) in target where t == .pinned(package) { target[id] = .foreground }
    }

    // MARK: 刷新

    /// 读取设备支持的所有分段：网络、开发者与前台 App 并行，系统在前台 App 之后（App 语言取当前目标）。
    func refreshAll(_ id: String) async {
        async let net: Void = refresh(id, section: .network)
        async let dev: Void = refresh(id, section: .devOptions)
        await refresh(id, section: .apps)
        await refresh(id, section: .system)
        _ = await (net, dev)
    }

    /// 读取一个分段；设备缺少该分段的能力时不读。
    func refresh(_ id: String, section: QuickSectionID) async {
        guard commands.can(section.capability, id) else { return }
        switch section {
        case .network: network[id] = await commands.readNetwork(id)
        case .apps: foreground[id] = await commands.readForegroundApp(id)
        case .devOptions: devOptions[id] = await commands.readDevOptions(id)
        case .system: system[id] = await commands.readSystem(id, appPackage: targetPackage(id))
        case .openURL, .custom: break
        }
    }

    // MARK: 修改

    func isBusy(_ id: String, _ section: QuickSectionID) -> Bool {
        busy.contains(Self.busyKey(id, section))
    }

    /// 切换网络开关：成功用回读值更新；失败重新读取，开关回到实际状态（spec §3.3）。
    func setNetwork(_ id: String, _ kind: NetworkKind, on: Bool) async {
        await whileBusy(id, .network) {
            if let state = await commands.setNetwork(id, kind, on: on) {
                network[id] = .success(state)
            } else {
                network[id] = await commands.readNetwork(id)
            }
        }
    }

    /// 对指定包名执行应用操作；会改变前台 App 的操作（除清数据外）之后重新读取前台 App。
    func appAction(_ id: String, _ action: AppAction, package: String) async {
        await whileBusy(id, .apps) {
            _ = await commands.appAction(id, action, package: package)
            guard action != .clearData else { return }
            let before = targetPackage(id)
            await refresh(id, section: .apps)
            // 目标跟随前台 App 且包名变了：App 语言要按新目标重读
            if currentTarget(id) == .foreground, targetPackage(id) != before {
                await refresh(id, section: .system)
            }
        }
    }

    /// 打开链接；空白输入不执行。成功后写入历史。
    @discardableResult
    func openURL(_ id: String, _ url: String) async -> Bool {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return false }
        var ok = false
        await whileBusy(id, .openURL) { ok = await commands.openURL(id, url, store: store) }
        return ok
    }

    /// 同一分段同时只做一次修改；进行中的分段在界面上显示进度。
    private func whileBusy(_ id: String, _ section: QuickSectionID, _ body: () async -> Void) async {
        let key = Self.busyKey(id, section)
        guard !busy.contains(key) else { return }
        busy.insert(key)
        await body()
        busy.remove(key)
    }

    static func busyKey(_ id: String, _ section: QuickSectionID) -> String { "\(id).\(section.rawValue)" }

    /// 读取失败的说明：信息加建议，用作悬停提示。
    static func reason(_ error: DeviceError) -> String {
        [error.message, error.suggestion].compactMap { $0 }.joined(separator: "，")
    }
}
