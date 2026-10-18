import DeviceCore
import Foundation

/// 面板上的应用操作。
enum AppAction {
    case launch, forceStop, clearData, restart, uninstall

    var verb: String {
        switch self {
        case .launch: "启动"
        case .forceStop: "强停"
        case .clearData: "清数据"
        case .restart: "重启"
        case .uninstall: "卸载"
        }
    }
}

/// 快捷操作的面板入口：读取不写记录；修改经 runner.perform 写记录，来源「你」。
extension DeviceCommands {
    // MARK: 读取

    func readNetwork(_ id: String) async -> Result<NetworkState, DeviceError> {
        await read(id) { try await $0.networkState() }
    }

    func readForegroundApp(_ id: String) async -> Result<AppInfo, DeviceError> {
        await read(id) { try await $0.foregroundApp() }
    }

    func readDevOptions(_ id: String) async -> Result<DevOptions, DeviceError> {
        await read(id) { try await $0.devOptions() }
    }

    func readSystem(_ id: String, appPackage: String?) async -> Result<SystemSettings, DeviceError> {
        await read(id) { try await $0.systemSettings(appPackage: appPackage) }
    }

    private func read<T>(_ id: String, _ body: (any DeviceActions) async throws -> T) async -> Result<T, DeviceError> {
        guard let actions = await actions(id) else {
            return .failure(DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用"))
        }
        do {
            return .success(try await body(actions))
        } catch let error as DeviceError {
            return .failure(error)
        } catch {
            return .failure(DeviceError(code: .CONNECTION_FAILED, message: String(describing: error)))
        }
    }

    // MARK: 修改

    /// 执行一次修改并写记录；设备不可用按 DEVICE_NOT_FOUND 记失败。
    private func mutate<T>(
        _ id: String, _ title: String, _ body: (any DeviceActions) async throws -> T
    ) async -> T? {
        guard let dev = device(id) else { return nil }
        return await runner.perform(title, device: dev) {
            guard let actions = await actions(id) else {
                throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用")
            }
            return try await body(actions)
        }
    }

    func setNetwork(_ id: String, _ kind: NetworkKind, on: Bool) async -> NetworkState? {
        let name = switch kind {
        case .wifi: on ? "打开 Wi-Fi" : "关闭 Wi-Fi"
        case .data: on ? "打开移动数据" : "关闭移动数据"
        case .airplane: on ? "开启飞行模式" : "关闭飞行模式"
        }
        return await mutate(id, name) { try await $0.setNetwork(kind, on: on) }
    }

    func appAction(_ id: String, _ action: AppAction, package: String) async -> Bool {
        let done: Void? = await mutate(id, "\(action.verb) \(package)") { (actions: any DeviceActions) async throws -> Void in
            switch action {
            case .launch: try await actions.launchApp(package)
            case .forceStop: try await actions.forceStop(package)
            case .clearData: try await actions.clearData(package)
            case .uninstall: try await actions.uninstall(package)
            case .restart:
                try await actions.forceStop(package)
                try await actions.launchApp(package)
            }
        }
        return done != nil
    }

    func openURL(_ id: String, _ url: String, store: QuickActionsStore) async -> Bool {
        let ok = await mutate(id, "打开链接 \(url)") { try await $0.openURL(url) } != nil
        if ok { store.recordURL(url) }
        return ok
    }

    func setDevOption(_ id: String, _ o: DevOption) async -> Bool {
        let title = switch o {
        case .showTouches(let on): "显示触摸点：\(Self.onOff(on))"
        case .layoutBounds(let on): "布局边界：\(Self.onOff(on))"
        case .stayAwake(let on): "保持唤醒：\(Self.onOff(on))"
        case .animationScale(let v): v == 0 ? "动画倍速：关" : "动画倍速：\(Self.number(v))x"
        }
        return await mutate(id, title) { try await $0.setDevOption(o) } != nil
    }

    func setSystem(_ id: String, _ s: SystemSetting) async -> Bool {
        let title = switch s {
        case .darkMode(let on): "深色模式：\(Self.onOff(on))"
        case .fontScale(let v): "字体大小：\(v)"
        case .appLocale(let package, let tag): "App 语言 \(package)：\(tag.isEmpty ? "跟随系统" : tag)"
        }
        return await mutate(id, title) { try await $0.setSystem(s) } != nil
    }

    func openSystemLocaleSettings(_ id: String) async {
        _ = await mutate(id, "打开系统语言设置") { try await $0.openSystemLocaleSettings() }
    }

    // MARK: 自定义命令

    /// 执行自定义命令；退出码非 0 或超时记为失败，但仍返回结果供界面显示输出。
    func runCustom(_ id: String, _ c: CustomCommand, package: String?) async -> ShellResult? {
        guard let dev = device(id) else { return nil }
        let title = "执行：\(c.name)"
        let result = await runner.perform(title, device: dev, logSuccess: false) {
            let command = try c.render(package: package)
            guard let actions = await actions(id) else {
                throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用")
            }
            return try await actions.shell(command, timeout: .seconds(30))
        }
        guard let result else { return nil }
        runner.note(title, device: dev, failure: result.failureNote)
        return result
    }

    // MARK: 确认

    /// 通过 Wi-Fi 连接的设备关闭 Wi-Fi 会断开自己，需先确认。
    static func needsWifiConfirmation(_ device: DeviceInfo, kind: NetworkKind, on: Bool) -> Bool {
        device.connection == .wifi && kind == .wifi && !on
    }

    private static func onOff(_ on: Bool) -> String { on ? "开" : "关" }

    /// 整数不带小数点：0.5 → "0.5"，2 → "2"。
    private static func number(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

extension ShellResult {
    /// 失败说明：超时或退出码非 0；成功为 nil。记录与面板输出共用。
    var failureNote: String? {
        timedOut ? "超时" : exitCode != 0 ? "退出码 \(exitCode)" : nil
    }
}
