import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

func uiDumpFixture() throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "ui-dump", withExtension: "xml", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct UIHierarchyParserTests {
    @Test func parsesRootSizeAndAllNodes() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture())
        #expect(tree.screen == CGSize(width: 1080, height: 2400))
        #expect(tree.elements.map(\.index) == Array(1...8))
        #expect(tree.elements[2].resourceID == "com.demo:id/login_btn" && tree.elements[2].clickable)
        #expect(tree.elements[4].editable)
    }
    @Test func defaultLinesListInterestingOnly() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture())
        let lines = tree.lines(all: false)
        #expect(lines.contains { $0.hasSuffix("Button \"登录\" id=login_btn (288,971)") })
        #expect(lines.contains { $0.contains("ImageView desc=\"返回\"") })
        #expect(lines.contains { $0.contains("EditText id=name") })
        #expect(!lines.contains { $0.contains("隐藏") })
        #expect(!lines.contains { $0.contains("FrameLayout") })
        #expect(lines.contains { $0.contains(#""他说\"好\"""#) })
    }
    @Test func allLinesIncludeEveryNode() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture())
        #expect(tree.lines(all: true).count == tree.elements.count)
    }
    @Test func matchingPrefersExact() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture())
        #expect(tree.matching(text: "登录").map(\.className) == ["android.widget.Button"])
        #expect(tree.matching(text: "帮助").map(\.text) == ["登录帮助"])
    }
    @Test func firstByIDAcceptsShortForm() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture())
        #expect(tree.first(text: nil, id: "login_btn")?.className == "android.widget.Button")
        #expect(tree.first(text: nil, id: "com.demo:id/login_btn")?.className == "android.widget.Button")
    }
    @Test func malformedXMLThrows() {
        #expect(throws: DeviceError.self) { try UIHierarchyParser.parse(Data("<hierarchy><node".utf8)) }
    }
    @Test func explicitScreenOverridesRootBounds() throws {
        let tree = try UIHierarchyParser.parse(uiDumpFixture(), screen: CGSize(width: 1080, height: 2500))
        #expect(tree.screen == CGSize(width: 1080, height: 2500))
    }
    @Test func parsesRotationAttribute() {
        #expect(UIHierarchyParser.rotation(in: Data(#"<?xml version='1.0'?><hierarchy rotation="1"><node/></hierarchy>"#.utf8)) == 1)
        #expect(UIHierarchyParser.rotation(in: Data("<hierarchy><node/></hierarchy>".utf8)) == nil)
    }
    @Test func parsesDumpsysCurSize() {
        let out = "  init=1440x3040 560dpi cur=1440x3040 app=1440x2838 rng=1440x1297-3040x2897\n"
        #expect(UIHierarchyParser.displaySize(dumpsys: out) == CGSize(width: 1440, height: 3040))
        #expect(UIHierarchyParser.displaySize(dumpsys: "nothing here") == nil)
    }
    @Test func parsesWmSize() {
        let physical = "Physical size: 1440x3040\n"
        let both = "Physical size: 1440x3040\nOverride size: 1080x2280\n"
        #expect(UIHierarchyParser.displaySize(wmSize: physical, rotation: 0) == CGSize(width: 1440, height: 3040))
        #expect(UIHierarchyParser.displaySize(wmSize: physical, rotation: 1) == CGSize(width: 3040, height: 1440))
        #expect(UIHierarchyParser.displaySize(wmSize: both, rotation: 3) == CGSize(width: 2280, height: 1080))
        #expect(UIHierarchyParser.displaySize(wmSize: "error", rotation: 0) == nil)
    }
}
