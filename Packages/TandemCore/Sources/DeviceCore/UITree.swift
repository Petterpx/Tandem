import Foundation

/// 界面上的一个节点；bounds 为设备像素。
public struct UIElement: Equatable, Sendable {
    public var index: Int
    public var className: String
    public var text: String
    public var contentDescription: String
    public var resourceID: String
    public var bounds: CGRect
    public var clickable: Bool
    public var longClickable: Bool
    public var scrollable: Bool
    public var checkable: Bool
    public var editable: Bool

    public init(
        index: Int, className: String, text: String, contentDescription: String, resourceID: String, bounds: CGRect,
        clickable: Bool, longClickable: Bool, scrollable: Bool, checkable: Bool, editable: Bool
    ) {
        self.index = index
        self.className = className
        self.text = text
        self.contentDescription = contentDescription
        self.resourceID = resourceID
        self.bounds = bounds
        self.clickable = clickable
        self.longClickable = longClickable
        self.scrollable = scrollable
        self.checkable = checkable
        self.editable = editable
    }

    /// 值得列给 AI 的节点：有面积，且可交互或带文字。
    public var isInteresting: Bool {
        guard !bounds.isEmpty else { return false }
        return clickable || longClickable || scrollable || checkable || editable
            || !text.isEmpty || !contentDescription.isEmpty
    }

    public var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
}

/// 一次界面结构快照。
public struct UITree: Equatable, Sendable {
    public var screen: CGSize
    public var elements: [UIElement]

    public init(screen: CGSize, elements: [UIElement]) {
        self.screen = screen
        self.elements = elements
    }

    public var space: CoordinateSpace? {
        CoordinateSpace(screenWidth: screen.width, screenHeight: screen.height)
    }

    /// `[<index>] <短类名>[ "<text>"][ desc="<desc>"][ id=<短 id>] (<cx>,<cy>)`，中心坐标在 AI 坐标空间内。
    public func line(for e: UIElement) -> String {
        var s = "[\(e.index)] \(e.className.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? e.className)"
        if !e.text.isEmpty { s += " \"\(Self.escaped(e.text))\"" }
        if !e.contentDescription.isEmpty { s += " desc=\"\(Self.escaped(e.contentDescription))\"" }
        if !e.resourceID.isEmpty { s += " id=\(Self.shortID(e.resourceID))" }
        let c = e.center
        if let space {
            let p = space.point(normalizedCenter(e))
            s += " (\(p.x),\(p.y))"
        } else {
            s += " (\(Int(c.x.rounded())),\(Int(c.y.rounded())))"
        }
        return s
    }

    public func lines(all: Bool) -> [String] {
        elements.filter { all || $0.isInteresting }.map { line(for: $0) }
    }

    public func element(index: Int) -> UIElement? {
        elements.first { $0.index == index }
    }

    /// text 或 desc 完全相等的元素；没有则返回包含该文字的元素。
    public func matching(text: String) -> [UIElement] {
        let exact = elements.filter { $0.text == text || $0.contentDescription == text }
        if !exact.isEmpty { return exact }
        return elements.filter { $0.text.contains(text) || $0.contentDescription.contains(text) }
    }

    /// `wait_for` 用：text 包含匹配 text 或 desc；id 与完整 id 或 `:id/` 之后部分相等；都给时都要满足。
    public func first(text: String?, id: String?) -> UIElement? {
        elements.first { e in
            if let text, !(e.text.contains(text) || e.contentDescription.contains(text)) { return false }
            if let id, !(e.resourceID == id || Self.shortID(e.resourceID) == id) { return false }
            return text != nil || id != nil
        }
    }

    public func normalizedCenter(_ e: UIElement) -> NormalizedPoint {
        guard screen.width > 0, screen.height > 0 else { return NormalizedPoint(x: 0, y: 0) }
        return NormalizedPoint(
            x: min(max(e.center.x / screen.width, 0), 1),
            y: min(max(e.center.y / screen.height, 0), 1)
        )
    }

    private static func shortID(_ id: String) -> String {
        guard let r = id.range(of: ":id/") else { return id }
        return String(id[r.upperBound...])
    }

    private static func escaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
