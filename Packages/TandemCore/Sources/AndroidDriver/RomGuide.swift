public struct RomGuide: Equatable, Sendable {
    public var brand: String
    public var steps: [String]

    public init(brand: String, steps: [String]) {
        self.brand = brand
        self.steps = steps
    }

    public static func forManufacturer(_ manufacturer: String) -> RomGuide {
        let m = manufacturer.lowercased()
        func has(_ keys: String...) -> Bool { keys.contains { m.contains($0) } }
        if has("xiaomi", "redmi", "poco") {
            return RomGuide(brand: "小米", steps: [
                "设置 → 更多设置 → 开发者选项",
                "打开「USB 调试（安全设置）」（可能需要登录小米账号并插入 SIM 卡）",
            ])
        }
        if has("oppo", "realme", "oneplus") {
            return RomGuide(brand: "OPPO / 一加 / realme", steps: [
                "设置 → 其他设置 → 开发者选项",
                "关闭「禁止权限监控」",
            ])
        }
        if has("vivo", "iqoo") {
            return RomGuide(brand: "vivo / iQOO", steps: [
                "设置 → 系统管理 → 开发者选项",
                "打开「USB 模拟点击」",
            ])
        }
        return RomGuide(brand: "该设备", steps: [
            "打开开发者选项",
            "查找与「USB 调试（安全设置）」或「模拟点击」相关的开关并打开",
        ])
    }
}
