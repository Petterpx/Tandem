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
    /// 各设备进行中的前台 App 读取数；读取期间上一次的包名不可用。
    private var readingForeground: [String: Int] = [:]
    /// 系统分段每次读取时用的目标包名（`SystemSettings.appLocale` 不带包名，靠它判断是否对应当前目标）。
    private var systemPackage: [String: String?] = [:]
    /// 正在修改的分段，键为 `"<id>.<section>"`。
    private(set) var busy: Set<String> = []
    /// 自定义命令最近一次的输出：设备 id → 命令 id → 结果；写入发起执行时的设备下。
    private(set) var lastOutput: [String: [UUID: CommandOutput]] = [:]

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

    /// 目标包名：前台 App 只在读取成功时有值，读不到或正在重读时为 nil，不沿用旧值。
    func targetPackage(_ id: String) -> String? {
        switch currentTarget(id) {
        case .foreground: isReadingForeground(id) ? nil : try? foreground[id]?.get().package
        case .pinned(let p): p
        }
    }

    func isReadingForeground(_ id: String) -> Bool { readingForeground[id, default: 0] > 0 }

    /// 系统分段的读取结果是否按当前目标读取；不是时 App 语言不能显示（可能是另一个包的语言）。
    func systemMatchesTarget(_ id: String) -> Bool {
        systemPackage[id] == .some(targetPackage(id))
    }

    /// 切换目标；系统分段的 App 语言随目标变化，重新读取。
    func setTarget(_ id: String, _ t: AppTarget) async {
        target[id] = t
        await refreshSystemIfTargetChanged(id)
    }

    /// 把前台 App 加入固定列表（所有设备共用）。
    func pinForeground(_ id: String) {
        guard case .success(let app)? = foreground[id], !app.package.isEmpty else { return }
        store.pin(app.package)
    }

    /// 移除固定；以它为目标的设备回到「前台 App」，并按新目标重读系统分段。
    func unpin(_ package: String) async {
        store.unpin(package)
        let affected = target.filter { $0.value == .pinned(package) }.map(\.key)
        for id in affected { target[id] = .foreground }
        for id in affected { await refreshSystemIfTargetChanged(id) }
    }

    // MARK: 刷新

    /// 读取设备支持的所有分段：网络、开发者与前台 App 并行，系统在前台 App 之后（App 语言取当前目标）。
    func refreshAll(_ id: String) async {
        async let net: Void = refresh(id, section: .network)
        async let dev: Void = refresh(id, section: .devOptions)
        await readForeground(id)
        await refresh(id, section: .system)
        _ = await (net, dev)
    }

    /// 读取一个分段；设备缺少该分段的能力时不读。
    func refresh(_ id: String, section: QuickSectionID) async {
        guard commands.can(section.capability, id) else { return }
        switch section {
        case .network: network[id] = await commands.readNetwork(id)
        case .apps:
            await readForeground(id)
            await refreshSystemIfTargetChanged(id)
        case .devOptions: devOptions[id] = await commands.readDevOptions(id)
        case .system:
            let package = targetPackage(id)
            system[id] = await commands.readSystem(id, appPackage: package)
            systemPackage[id] = .some(package)
        case .openURL, .custom: break
        }
    }

    /// 读取前台 App；读取期间目标包名为 nil，避免对上一次的包名操作。
    private func readForeground(_ id: String) async {
        guard commands.can(.apps, id) else { return }
        readingForeground[id, default: 0] += 1
        foreground[id] = await commands.readForegroundApp(id)
        readingForeground[id, default: 1] -= 1
    }

    /// 目标包名与系统分段上次读取时不同：App 语言要按新目标重读。
    private func refreshSystemIfTargetChanged(_ id: String) async {
        guard !systemMatchesTarget(id) else { return }
        await refresh(id, section: .system)
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

    /// 恢复默认网络：按当前读数计算步骤，无事可做时直接返回；无论成败都回读真实状态。
    func resetNetwork(_ id: String) async {
        await whileBusy(id, .network) {
            let current = try? network[id]?.get()
            let steps = DeviceCommands.resetNetworkSteps(current)
            guard !steps.isEmpty else { return }
            _ = await commands.resetNetwork(id, steps: steps)
            network[id] = await commands.readNetwork(id)
        }
    }

    /// 对指定包名执行应用操作；会改变前台 App 的操作（除清数据外）之后重新读取前台 App。
    func appAction(_ id: String, _ action: AppAction, package: String) async {
        await whileBusy(id, .apps) {
            _ = await commands.appAction(id, action, package: package)
            guard action != .clearData else { return }
            // 前台 App 变了时，refresh 会按新目标重读系统分段
            await refresh(id, section: .apps)
        }
    }

    /// 修改开发者选项；无论成败都重新读取该分段，界面显示实际值（spec §3.2）。
    func setDevOption(_ id: String, _ o: DevOption) async {
        await whileBusy(id, .devOptions) {
            _ = await commands.setDevOption(id, o)
            await refresh(id, section: .devOptions)
        }
    }

    /// 修改系统设置；无论成败都重新读取该分段。
    func setSystem(_ id: String, _ s: SystemSetting) async {
        await whileBusy(id, .system) {
            _ = await commands.setSystem(id, s)
            await refresh(id, section: .system)
        }
    }

    func openSystemLocaleSettings(_ id: String) async {
        await commands.openSystemLocaleSettings(id)
    }

    // MARK: 自定义命令

    func isRunning(_ id: String, _ command: UUID) -> Bool {
        busy.contains(Self.runKey(id, command))
    }

    /// 执行自定义命令，输出按命令保存；没有结果（设备不可用、缺少包名等，失败已写入记录）时清掉旧输出。
    func runCustom(_ id: String, _ c: CustomCommand, package: String?) async {
        await whileBusy(key: Self.runKey(id, c.id)) {
            let result = await commands.runCustom(id, c, package: package)
            lastOutput[id, default: [:]][c.id] = result.map(CommandOutput.init)
        }
    }

    /// 该设备上这条命令最近一次的输出。
    func output(_ id: String, _ command: UUID) -> CommandOutput? { lastOutput[id]?[command] }

    func removeCommand(_ command: UUID) {
        store.removeCommand(id: command)
        // 命令是全局的：所有设备上的输出一并清掉
        for id in lastOutput.keys { lastOutput[id]?[command] = nil }
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
        await whileBusy(key: Self.busyKey(id, section), body)
    }

    private func whileBusy(key: String, _ body: () async -> Void) async {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        await body()
        busy.remove(key)
    }

    static func busyKey(_ id: String, _ section: QuickSectionID) -> String { "\(id).\(section.rawValue)" }

    /// 每条自定义命令单独占一个 busy 键，可同时执行不同的命令。
    static func runKey(_ id: String, _ command: UUID) -> String { "\(busyKey(id, .custom)).\(command.uuidString)" }

    /// 读取失败的说明：信息加建议，用作悬停提示。
    static func reason(_ error: DeviceError) -> String {
        [error.message, error.suggestion].compactMap { $0 }.joined(separator: "，")
    }
}

/// 自定义命令的一次输出：保存时就合并、截断好（最多 200 行、256 KB），视图每次渲染不再处理原始大文本。
struct CommandOutput: Equatable {
    var text: String
    /// 失败说明（超时或退出码），成功为 nil。
    var failure: String?
}

extension CommandOutput {
    init(_ result: ShellResult) {
        text = QuickActionsStore.cappedOutput(QuickActionsStore.joinedOutput(stdout: result.stdout, stderr: result.stderr))
        failure = result.failureNote
    }
}
