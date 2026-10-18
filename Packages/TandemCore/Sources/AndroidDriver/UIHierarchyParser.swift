import Foundation
import DeviceCore

/// 解析 `uiautomator dump` 产出的 XML。
enum UIHierarchyParser {
    /// `screen` 为显示器尺寸（当前朝向）；nil 时退回根节点 bounds（根节点是前台窗口，可能不含导航栏）。
    static func parse(_ xml: Data, screen: CGSize? = nil) throws -> UITree {
        let delegate = Delegate()
        let parser = XMLParser(data: xml)
        parser.delegate = delegate
        guard parser.parse(), let first = delegate.elements.first else {
            throw DeviceError(
                code: .CONNECTION_FAILED,
                message: "界面结构数据无效",
                suggestion: "请稍后重试或改用截图"
            )
        }
        return UITree(screen: screen ?? first.bounds.size, elements: delegate.elements)
    }

    /// `<hierarchy rotation="N">` 中的 N（0…3）；缺失返回 nil。
    static func rotation(in xml: Data) -> Int? {
        let s = String(decoding: xml.prefix(4096), as: UTF8.self)
        guard let m = firstMatch(#"rotation="(\d)""#, in: s) else { return nil }
        return Int(m[0])
    }

    /// `dumpsys window displays` 中第一个 `cur=<W>x<H>`：当前朝向且含分辨率覆盖的显示尺寸。
    static func displaySize(dumpsys output: String) -> CGSize? {
        guard let m = firstMatch(#"\bcur=(\d+)x(\d+)"#, in: output), m[0] > 0, m[1] > 0 else { return nil }
        return CGSize(width: m[0], height: m[1])
    }

    /// `wm size` 输出：优先 `Override size`，否则 `Physical size`；竖屏基准尺寸，按 rotation 1/3 交换宽高。
    static func displaySize(wmSize output: String, rotation: Int?) -> CGSize? {
        var physical: CGSize?
        var override: CGSize?
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            guard let m = firstMatch(#"(\d+)x(\d+)"#, in: line), m[0] > 0, m[1] > 0 else { continue }
            if line.contains("Override size") { override = CGSize(width: m[0], height: m[1]) }
            else if line.contains("Physical size") { physical = CGSize(width: m[0], height: m[1]) }
        }
        guard let size = override ?? physical else { return nil }
        return rotation == 1 || rotation == 3 ? CGSize(width: size.height, height: size.width) : size
    }

    private static func firstMatch(_ pattern: String, in s: String) -> [Double]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).compactMap { Double(ns.substring(with: m.range(at: $0))) }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var elements: [UIElement] = []
        // 与 Swift Regex 相比，NSRegularExpression 更省事且不受并发隔离影响。
        private let boundsPattern = try! NSRegularExpression(pattern: #"\[(\d+),(\d+)\]\[(\d+),(\d+)\]"#)

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
            guard name == "node" else { return }
            let cls = a["class"] ?? ""
            elements.append(UIElement(
                index: elements.count + 1,
                className: cls,
                text: a["text"] ?? "",
                contentDescription: a["content-desc"] ?? "",
                resourceID: a["resource-id"] ?? "",
                bounds: bounds(a["bounds"] ?? ""),
                clickable: a["clickable"] == "true",
                longClickable: a["long-clickable"] == "true",
                scrollable: a["scrollable"] == "true",
                checkable: a["checkable"] == "true",
                editable: cls.hasSuffix("EditText")
            ))
        }

        private func bounds(_ s: String) -> CGRect {
            let ns = s as NSString
            guard let m = boundsPattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return .zero }
            let v = (1...4).map { Double(ns.substring(with: m.range(at: $0))) ?? 0 }
            return CGRect(x: v[0], y: v[1], width: max(v[2] - v[0], 0), height: max(v[3] - v[1], 0))
        }
    }
}
