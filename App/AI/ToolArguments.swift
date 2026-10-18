import ControlProtocol
import DeviceCore

/// tools/call 的参数读取：类型不对或缺少必填参数时抛 INVALID_ARGUMENT，让 AI 看到后自行调整。
struct ToolArguments {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    private func invalid(_ name: String, _ what: String) -> DeviceError {
        DeviceError(code: .INVALID_ARGUMENT, message: "参数 \(name) \(what)")
    }

    /// 缺省或 null 视为未提供。
    private func value(_ name: String) -> JSONValue? {
        guard let v = values[name], v != .null else { return nil }
        return v
    }

    func string(_ name: String) throws -> String? {
        guard let v = value(name) else { return nil }
        guard let s = v.stringValue else { throw invalid(name, "应为字符串") }
        return s
    }

    /// 空字符串视为不合法（匹配或输入空内容没有意义）。
    func nonEmptyString(_ name: String) throws -> String? {
        guard let s = try string(name) else { return nil }
        guard !s.isEmpty else { throw invalid(name, "不能为空") }
        return s
    }

    func double(_ name: String) throws -> Double? {
        guard let v = value(name) else { return nil }
        guard let d = v.doubleValue else { throw invalid(name, "应为数字") }
        return d
    }

    func int(_ name: String) throws -> Int? {
        guard let v = value(name) else { return nil }
        guard let i = v.intValue else { throw invalid(name, "应为整数") }
        return i
    }

    func bool(_ name: String) throws -> Bool? {
        guard let v = value(name) else { return nil }
        guard let b = v.boolValue else { throw invalid(name, "应为布尔值") }
        return b
    }

    func requiredString(_ name: String) throws -> String {
        guard let s = try string(name) else { throw invalid(name, "必填") }
        return s
    }

    func requiredNonEmptyString(_ name: String) throws -> String {
        guard let s = try nonEmptyString(name) else { throw invalid(name, "必填") }
        return s
    }

    func requiredDouble(_ name: String) throws -> Double {
        guard let d = try double(name) else { throw invalid(name, "必填") }
        return d
    }

    func requiredBool(_ name: String) throws -> Bool {
        guard let b = try bool(name) else { throw invalid(name, "必填") }
        return b
    }

    /// 整数参数的范围检查。
    func int(_ name: String, in range: ClosedRange<Int>, default fallback: Int) throws -> Int {
        guard let i = try int(name) else { return fallback }
        guard range.contains(i) else { throw invalid(name, "须在 \(range.lowerBound) 到 \(range.upperBound) 之间") }
        return i
    }

    /// x、y 必须成对出现。
    func point(_ x: String, _ y: String) throws -> (x: Double, y: Double)? {
        let px = try double(x), py = try double(y)
        switch (px, py) {
        case (nil, nil): return nil
        case (let px?, let py?): return (px, py)
        default: throw invalid(px == nil ? x : y, "必须与 \(px == nil ? y : x) 同时提供")
        }
    }
}
