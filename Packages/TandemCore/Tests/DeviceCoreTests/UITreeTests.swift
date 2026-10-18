import Testing
import Foundation
@testable import DeviceCore

private func el(_ i: Int, _ cls: String = "android.widget.TextView", text: String = "", desc: String = "", id: String = "",
                bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100), clickable: Bool = false) -> UIElement {
    UIElement(index: i, className: cls, text: text, contentDescription: desc, resourceID: id, bounds: bounds,
              clickable: clickable, longClickable: false, scrollable: false, checkable: false, editable: false)
}

@Suite struct UITreeTests {
    private let tree = UITree(screen: CGSize(width: 1080, height: 2400), elements: [
        el(1, "android.widget.FrameLayout", bounds: CGRect(x: 0, y: 0, width: 1080, height: 2400)),
        el(2, "android.widget.Button", text: "登录", id: "com.demo:id/login_btn", bounds: CGRect(x: 340, y: 1720, width: 400, height: 200), clickable: true),
        el(3, text: "登录帮助"),
        el(4, text: "他说\"好\"\n再见"),
    ])

    @Test func lineFormat() {
        #expect(tree.line(for: tree.elements[1]) == "[2] Button \"登录\" id=login_btn (288,971)")
        #expect(tree.line(for: tree.elements[3]).contains(#""他说\"好\" 再见""#))
    }
    @Test func interestingFilter() {
        #expect(tree.lines(all: false).count == 3)
        #expect(tree.lines(all: true).count == 4)
    }
    @Test func matchingPrefersExact() {
        #expect(tree.matching(text: "登录").map(\.index) == [2])
        #expect(tree.matching(text: "帮助").map(\.index) == [3])
    }
    @Test func firstByIDAndText() {
        #expect(tree.first(text: nil, id: "login_btn")?.index == 2)
        #expect(tree.first(text: nil, id: "com.demo:id/login_btn")?.index == 2)
        #expect(tree.first(text: "登录", id: "login_btn")?.index == 2)
        #expect(tree.first(text: "帮助", id: "login_btn") == nil)
        #expect(tree.element(index: 3)?.text == "登录帮助")
    }
    @Test func normalizedCenterUsesDeviceFraction() {
        let p = tree.normalizedCenter(tree.elements[1])
        #expect(abs(p.x - 0.5) < 1e-9 && abs(p.y - 1820.0 / 2400) < 1e-9)
    }
    @Test func bottomElementOfAppWindowMapsAgainstDisplaySize() {
        // 应用窗口 1440x2838（不含导航栏），显示器 1440x3040：坐标须按显示器换算，与截图同一空间。
        let t = UITree(screen: CGSize(width: 1440, height: 3040), elements: [
            el(1, bounds: CGRect(x: 0, y: 2700, width: 1440, height: 200)),
        ])
        let expected = Int((2800.0 / 3040 * 1280).rounded())
        #expect(t.line(for: t.elements[0]).hasSuffix(",\(expected))"))
        #expect(abs(t.normalizedCenter(t.elements[0]).y - 2800.0 / 3040) < 1e-9)
    }
}
