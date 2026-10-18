import ControlProtocol
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ToolRegistryQuickTests {
    private static let p2Names = [
        "list_devices", "screenshot", "get_ui_tree", "wait_for", "tap", "long_press", "swipe", "scroll",
        "type_text", "press_key", "get_clipboard", "set_clipboard",
    ]
    private static let quickNames = [
        "current_app", "launch_app", "force_stop", "clear_app_data", "uninstall_app", "open_url",
        "get_network_state", "set_network", "get_dev_options", "set_dev_option", "get_system_settings",
        "set_system", "shell",
    ]

    /// 与 AIEnv.pixel 同一台设备（逻辑 id 相同），声明全部快捷操作能力。
    private static let quickPixel: DeviceInfo = {
        var d = AIEnv.pixel
        d.capabilities.formUnion([.network, .apps, .openURL, .devOptions, .systemSettings, .shell])
        return d
    }()

    private func text(_ r: ToolResult) -> String {
        guard case .text(let t) = r.content.first else { return "" }
        return t
    }

    private func env() -> (AIEnv, RecordingActions) {
        let actions = RecordingActions()
        let e = AIEnv(devices: [Self.quickPixel], actions: actions, hasSession: false, sleep: { _ in })
        return (e, actions)
    }

    /// 逐个调用，全部应为 INVALID_ARGUMENT，且不触达设备操作。
    private func expectInvalid(_ cases: [(String, [String: JSONValue])]) async throws {
        let (e, actions) = env()
        let r = ToolRegistry(commands: e.commands)
        for (name, args) in cases {
            let result = try await r.call(name, arguments: args)
            #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"), "\(name) \(args) → \(text(result))")
        }
        withExtendedLifetime(e) {}
        #expect(actions.calls.isEmpty)
    }

    @Test func newToolsListedInSpecOrder() {
        let e = AIEnv()
        let r = ToolRegistry(commands: e.commands)
        #expect(r.descriptors(for: []).map(\.name) == Self.p2Names + Self.quickNames)
        withExtendedLifetime(e) {}
    }

    @Test func quickToolsFilteredByCapability() {
        let e = AIEnv()
        let r = ToolRegistry(commands: e.commands)
        var d = AIEnv.pixel
        d.capabilities = [.network, .shell]
        #expect(r.descriptors(for: [d]).map(\.name) == ["list_devices", "get_network_state", "set_network", "shell"])
        d.capabilities = [.apps]
        #expect(
            r.descriptors(for: [d]).map(\.name)
                == ["list_devices", "current_app", "launch_app", "force_stop", "clear_app_data", "uninstall_app"])
        d.capabilities = [.openURL, .devOptions, .systemSettings]
        #expect(
            r.descriptors(for: [d]).map(\.name)
                == ["list_devices", "open_url", "get_dev_options", "set_dev_option", "get_system_settings", "set_system"])
        withExtendedLifetime(e) {}
    }

    @Test func packageRequired() async throws {
        let e = AIEnv()
        let schemas = Dictionary(
            uniqueKeysWithValues: ToolRegistry(commands: e.commands).descriptors(for: []).map { ($0.name, $0) })
        withExtendedLifetime(e) {}
        for name in ["launch_app", "force_stop", "clear_app_data", "uninstall_app"] {
            #expect(schemas[name]?.inputSchema["required"] == ["package"], "\(name)")
        }
        #expect(schemas["shell"]?.inputSchema["required"] == ["command"])
        #expect(schemas["get_system_settings"]?.inputSchema["required"] == [])
        try await expectInvalid([
            ("launch_app", [:]), ("force_stop", [:]), ("clear_app_data", [:]), ("uninstall_app", [:]),
            ("clear_app_data", ["package": ""]), ("uninstall_app", ["package": 1]),
            ("open_url", [:]), ("open_url", ["url": ""]),
        ])
    }

    @Test func setNetworkValidated() async throws {
        try await expectInvalid([
            ("set_network", ["kind": "bluetooth", "on": true]),
            ("set_network", ["kind": "wifi"]),
            ("set_network", ["kind": "wifi", "on": 1]),
            ("set_network", ["on": false]),
        ])
    }

    @Test func devOptionValueValidated() async throws {
        try await expectInvalid([
            ("set_dev_option", ["option": "animation_scale", "value": true]),
            ("set_dev_option", ["option": "animation_scale", "value": 3]),
            ("set_dev_option", ["option": "show_touches", "value": 2]),
            ("set_dev_option", ["option": "stay_awake", "value": 1]),
            ("set_dev_option", ["option": "layout_bounds"]),
            ("set_dev_option", ["option": "gpu", "value": true]),
        ])
    }

    @Test func systemValueValidated() async throws {
        try await expectInvalid([
            ("set_system", ["setting": "dark_mode", "value": 1]),
            ("set_system", ["setting": "font_scale", "value": 1.2]),
            ("set_system", ["setting": "font_scale", "value": true]),
            ("set_system", ["setting": "app_locale", "package": "com.demo", "value": 1]),
            ("set_system", ["setting": "language", "value": "en"]),
        ])
    }

    @Test func appLocaleNeedsPackage() async throws {
        try await expectInvalid([
            ("set_system", ["setting": "app_locale", "value": "en"]),
            ("set_system", ["setting": "app_locale", "value": ""]),
            ("set_system", ["setting": "app_locale", "package": "", "value": "en"]),
        ])
    }

    @Test func shellCommandMustBeNonEmpty() async throws {
        try await expectInvalid([("shell", [:]), ("shell", ["command": ""]), ("shell", ["command": "  \n"])])
    }

    @Test func validArgumentsReachDevice() async throws {
        let (e, actions) = env()
        let r = ToolRegistry(commands: e.commands)
        let calls: [(String, [String: JSONValue])] = [
            ("current_app", [:]),
            ("launch_app", ["package": "com.demo"]),
            ("set_network", ["kind": "data", "on": false]),
            ("set_dev_option", ["option": "animation_scale", "value": 0.5]),
            ("set_dev_option", ["option": "show_touches", "value": true]),
            ("set_system", ["setting": "font_scale", "value": 1]),
            ("set_system", ["setting": "app_locale", "package": "com.demo", "value": ""]),
            ("get_system_settings", ["package": "com.demo"]),
            ("shell", ["command": "ls"]),
        ]
        for (name, args) in calls {
            let result = try await r.call(name, arguments: args)
            #expect(!result.isError, "\(name) → \(text(result))")
        }
        withExtendedLifetime(e) {}
        let made = actions.calls
        #expect(made.contains("launchApp com.demo"))
        #expect(made.contains("setNetwork data false"))
        #expect(made.contains("setDevOption animationScale(0.5)"))
        #expect(made.contains("setDevOption showTouches(true)"))
        #expect(made.contains("setSystem fontScale(1.0)"))
        #expect(made.contains(#"setSystem appLocale(package: "com.demo", tag: "")"#))
        #expect(made.contains("systemSettings com.demo"))
        #expect(made.contains("shell ls"))
    }

    @Test func shellHiddenAndRejectedWhenDisabled() async throws {
        var allowed = false
        let (e, actions) = env()
        let r = ToolRegistry(commands: e.commands, allowShell: { allowed })
        #expect(!r.descriptors(for: []).map(\.name).contains("shell"))
        #expect(!r.descriptors(for: [Self.quickPixel]).map(\.name).contains("shell"))
        let rejected = try await r.call("shell", arguments: ["command": "ls"])
        #expect(rejected.isError && text(rejected) == "UNSUPPORTED: 已在 Tandem 设置中关闭")
        #expect(actions.calls.isEmpty)
        let list = text(try await r.call("list_devices", arguments: [:]))
        #expect(list.contains("set_system") && !list.contains("shell"))

        allowed = true
        #expect(r.descriptors(for: [Self.quickPixel]).map(\.name).last == "shell")
        let ok = try await r.call("shell", arguments: ["command": "ls"])
        #expect(!ok.isError)
        withExtendedLifetime(e) {}
    }

    @Test func shellTimeoutCoversDeviceTimeout() {
        #expect(ToolRegistry.timeout(for: "shell", arguments: [:]) == .seconds(40))
        #expect(ToolRegistry.timeout(for: "set_network", arguments: [:]) == .seconds(30))
    }
}
