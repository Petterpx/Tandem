import Foundation
import DeviceCore

/// 解析 `uiautomator dump` 产出的 XML。
enum UIHierarchyParser {
    static func parse(_ xml: Data) throws -> UITree {
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
        return UITree(screen: first.bounds.size, elements: delegate.elements)
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
