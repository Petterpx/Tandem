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
}
