import ControlProtocol
import DeviceCore
import Foundation

/// 快捷操作工具（spec §4）：都不需要投屏会话。参数在这里校验，包名格式由核心层校验。
extension ToolRegistry {
    static let shellTool = "shell"

    private static let networkKinds = NetworkKind.allCases.map(\.rawValue)
    private static let devOptionNames = ["show_touches", "layout_bounds", "stay_awake", "animation_scale"]
    private static let systemSettingNames = ["dark_mode", "font_scale", "app_locale"]
    /// 错误信息与描述里列出的可选值，写法照 spec：「0、0.5、1、2、5、10」「0.85、1.0、1.15、1.3」。
    private static let animationScaleList = DevOption.animationScales
        .map(\.compactText).joined(separator: "、")
    private static let fontScaleList = SystemSetting.fontScales.map { String($0) }.joined(separator: "、")

    private static func enumeration(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map { .string($0) }), "description": .string(description)]
    }

    private static func packageProperty(_ description: String = "App 包名，如 com.example.app") -> [String: JSONValue] {
        ["package": string(description)]
    }

    private static func invalid(_ message: String) -> DeviceError {
        DeviceError(code: .INVALID_ARGUMENT, message: message)
    }

    static func quickTools(_ c: AICommands) -> [Tool] {
        [
            // MARK: 应用
            Tool(
                name: "current_app", description: "读取前台 App：包名、Activity、版本。",
                properties: [:], required: [], capability: .apps,
                run: { _, d in .text(try await c.currentApp(d)) }),
            Tool(
                name: "launch_app", description: "启动 App（打开其启动页）。",
                properties: packageProperty(), required: ["package"], capability: .apps,
                run: { a, d in .text(try await c.launchApp(d, package: try a.requiredNonEmptyString("package"))) }),
            Tool(
                name: "force_stop", description: "强行停止 App。",
                properties: packageProperty(), required: ["package"], capability: .apps,
                run: { a, d in .text(try await c.forceStop(d, package: try a.requiredNonEmptyString("package"))) }),
            Tool(
                name: "clear_app_data", description: "清除 App 的全部数据（破坏性操作，不可恢复），须显式给出包名。",
                properties: packageProperty(), required: ["package"], capability: .apps,
                run: { a, d in .text(try await c.clearAppData(d, package: try a.requiredNonEmptyString("package"))) }),
            Tool(
                name: "uninstall_app", description: "卸载 App（破坏性操作，不可恢复），须显式给出包名。",
                properties: packageProperty(), required: ["package"], capability: .apps,
                run: { a, d in .text(try await c.uninstallApp(d, package: try a.requiredNonEmptyString("package"))) }),
            Tool(
                name: "open_url", description: "用系统默认方式打开链接（网页或 App 深链接）。",
                properties: ["url": string("要打开的链接，如 https://example.com 或 myapp://page")],
                required: ["url"], capability: .openURL,
                run: { a, d in .text(try await c.openURL(d, url: try a.requiredNonEmptyString("url"))) }),

            // MARK: 网络
            Tool(
                name: "get_network_state", description: "读取 Wi-Fi、移动数据、飞行模式的开关状态（读不到为 unknown）。",
                properties: [:], required: [], capability: .network,
                run: { _, d in .text(try await c.networkState(d)) }),
            Tool(
                name: "set_network",
                description: "打开或关闭 Wi-Fi、移动数据或飞行模式，返回回读后的实际状态。飞行模式需要 Android 11+；"
                    + "设备经 Wi-Fi 调试连接时不能关闭 Wi-Fi。",
                properties: [
                    "kind": enumeration(networkKinds, "开关种类"), "on": boolean("true 为打开，false 为关闭"),
                ],
                required: ["kind", "on"], capability: .network,
                run: { a, d in
                    guard let kind = NetworkKind(rawValue: try a.requiredString("kind")) else {
                        throw invalid("参数 kind 应为 " + networkKinds.joined(separator: "、") + " 之一")
                    }
                    return .text(try await c.setNetwork(d, kind: kind, on: try a.requiredBool("on")))
                }),

            // MARK: 开发者选项
            Tool(
                name: "get_dev_options", description: "读取开发者选项：显示触摸点、布局边界、保持唤醒、动画倍速（读不到为 unknown）。",
                properties: [:], required: [], capability: .devOptions,
                run: { _, d in .text(try await c.devOptions(d)) }),
            Tool(
                name: "set_dev_option",
                description: "设置一项开发者选项。show_touches、layout_bounds、stay_awake 的 value 为布尔值；"
                    + "animation_scale 的 value 为数字，仅 \(animationScaleList)（同时设置三项动画倍速）。",
                properties: [
                    "option": enumeration(devOptionNames, "选项"),
                    "value": ["type": ["boolean", "number"], "description": "开关项为布尔值，animation_scale 为数字"],
                ],
                required: ["option", "value"], capability: .devOptions,
                run: { a, d in .text(try await c.setDevOption(d, try devOption(a))) }),

            // MARK: 系统设置
            Tool(
                name: "get_system_settings", description: "读取深色模式、字体大小；给出 package 时附该 App 的语言。",
                properties: packageProperty("App 包名；给出时附该 App 的语言"), required: [], capability: .systemSettings,
                run: { a, d in
                    // 空字符串视为未提供
                    let package = try a.string("package").flatMap { $0.isEmpty ? nil : $0 }
                    return .text(try await c.systemSettings(d, package: package))
                }),
            Tool(
                name: "set_system",
                description: "设置一项系统设置。dark_mode 的 value 为布尔值；font_scale 的 value 为数字，仅 "
                    + "\(fontScaleList)；app_locale 的 value 为 BCP 47 语言标签（如 zh-CN、en）或空字符串"
                    + "（跟随系统），且须给出 package，需要 Android 13+。",
                properties: [
                    "setting": enumeration(systemSettingNames, "设置项"),
                    "value": ["type": ["boolean", "number", "string"], "description": "取值，类型随 setting 而定"],
                    "package": string("App 包名，app_locale 时必填"),
                ],
                required: ["setting", "value"], capability: .systemSettings,
                run: { a, d in .text(try await c.setSystem(d, try systemSetting(a))) }),

            // MARK: shell
            Tool(
                name: shellTool,
                description: "在设备上执行 adb shell 命令，返回退出码、stdout 与 stderr；退出码非 0 不算失败。"
                    + "超时 30 秒（返回 TIMEOUT 并附部分输出），输出超过 64 KB 截断并注明。",
                properties: ["command": string("要执行的 shell 命令")],
                required: ["command"], capability: .shell,
                run: { a, d in
                    let command = try a.requiredString("command")
                    guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw invalid("参数 command 不能为空")
                    }
                    return .text(try await c.shell(d, command: command))
                }),
        ]
    }

    /// set_dev_option 的 option 与 value：开关项只收布尔值，animation_scale 只收可选值内的数字。
    private static func devOption(_ a: ToolArguments) throws -> DevOption {
        switch try a.requiredString("option") {
        case "show_touches": return .showTouches(try a.requiredBool("value"))
        case "layout_bounds": return .layoutBounds(try a.requiredBool("value"))
        case "stay_awake": return .stayAwake(try a.requiredBool("value"))
        case "animation_scale":
            let scale = try a.requiredDouble("value")
            guard DevOption.animationScales.contains(scale) else {
                throw invalid("参数 value 应为 \(animationScaleList) 之一")
            }
            return .animationScale(scale)
        default:
            throw invalid("参数 option 应为 " + devOptionNames.joined(separator: "、") + " 之一")
        }
    }

    /// set_system 的 setting 与 value；app_locale 另需 package（value 可为空字符串，表示跟随系统）。
    private static func systemSetting(_ a: ToolArguments) throws -> SystemSetting {
        switch try a.requiredString("setting") {
        case "dark_mode": return .darkMode(try a.requiredBool("value"))
        case "font_scale":
            let scale = try a.requiredDouble("value")
            guard SystemSetting.fontScales.contains(scale) else {
                throw invalid("参数 value 应为 \(fontScaleList) 之一")
            }
            return .fontScale(scale)
        case "app_locale":
            let tag = try a.requiredString("value")
            guard let package = try a.nonEmptyString("package") else {
                throw invalid("设置 app_locale 时参数 package 必填")
            }
            return .appLocale(package: package, tag: tag)
        default:
            throw invalid("参数 setting 应为 " + systemSettingNames.joined(separator: "、") + " 之一")
        }
    }
}
