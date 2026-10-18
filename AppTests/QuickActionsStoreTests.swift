import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct QuickActionsStoreTests {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: UUID().uuidString)! }

    @Test func pinsDeduplicateAndPersist() {
        let defaults = makeDefaults()
        let store = QuickActionsStore(defaults: defaults)
        store.pin("com.a"); store.pin("com.b"); store.pin("com.a")
        #expect(store.pinnedPackages == ["com.a", "com.b"])
        #expect(QuickActionsStore(defaults: defaults).pinnedPackages == ["com.a", "com.b"])
        store.unpin("com.a")
        #expect(QuickActionsStore(defaults: defaults).pinnedPackages == ["com.b"])
    }

    @Test func urlHistoryKeeps20MostRecentFirst() {
        let defaults = makeDefaults()
        let store = QuickActionsStore(defaults: defaults)
        for i in 0..<25 { store.recordURL("https://e.com/\(i)") }
        #expect(store.urlHistory.count == 20)
        #expect(store.urlHistory.first == "https://e.com/24")
        store.recordURL("https://e.com/10")
        #expect(store.urlHistory.first == "https://e.com/10")
        #expect(store.urlHistory.filter { $0 == "https://e.com/10" }.count == 1)
        #expect(QuickActionsStore(defaults: defaults).urlHistory == store.urlHistory)
        store.removeURL("https://e.com/10")
        #expect(!store.urlHistory.contains("https://e.com/10"))
    }

    @Test func commandsPersistAndReorder() {
        let defaults = makeDefaults()
        let store = QuickActionsStore(defaults: defaults)
        store.addCommand(name: "a", command: "echo a")
        store.addCommand(name: "b", command: "echo b")
        store.addCommand(name: "c", command: "echo c")
        store.moveCommands(from: IndexSet(integer: 2), to: 0)
        #expect(store.commands.map(\.name) == ["c", "a", "b"])
        var edited = store.commands[1]
        edited.command = "echo A"
        store.updateCommand(edited)
        let reloaded = QuickActionsStore(defaults: defaults)
        #expect(reloaded.commands.map(\.name) == ["c", "a", "b"])
        #expect(reloaded.commands[1].command == "echo A")
        reloaded.removeCommand(id: edited.id)
        #expect(QuickActionsStore(defaults: defaults).commands.map(\.name) == ["c", "b"])
    }

    @Test func sectionsToggleAndPersist() {
        let defaults = makeDefaults()
        let store = QuickActionsStore(defaults: defaults)
        store.toggleSection("network")
        #expect(QuickActionsStore(defaults: defaults).collapsedSections == ["network"])
        store.toggleSection("network")
        #expect(QuickActionsStore(defaults: defaults).collapsedSections.isEmpty)
    }

    @Test func allowAIShellDefaultsTrue() {
        let defaults = makeDefaults()
        let store = QuickActionsStore(defaults: defaults)
        #expect(store.allowAIShell)
        store.allowAIShell = false
        #expect(!QuickActionsStore(defaults: defaults).allowAIShell)
    }

    @Test func placeholderIsQuoted() throws {
        let cmd = CustomCommand(id: UUID(), name: "stop", command: "am force-stop {package}")
        #expect(cmd.needsPackage)
        #expect(try cmd.render(package: "com.demo") == "am force-stop 'com.demo'")
        #expect(throws: DeviceError.self) { try cmd.render(package: "x';reboot") }
        do { _ = try cmd.render(package: "x';reboot") } catch let e as DeviceError {
            #expect(e.code == .INVALID_ARGUMENT)
        }
        do { _ = try cmd.render(package: nil); Issue.record("应抛错") } catch let e as DeviceError {
            #expect(e.code == .INVALID_ARGUMENT)
            #expect(e.message == "该命令需要目标 App")
        }
        let plain = CustomCommand(id: UUID(), name: "p", command: "echo hi")
        #expect(try plain.render(package: nil) == "echo hi")
    }

    @Test func outputIsCappedAt200Lines() {
        let input = (1...250).map { "line \($0)" }.joined(separator: "\n")
        let out = QuickActionsStore.cappedOutput(input)
        let lines = out.components(separatedBy: "\n")
        #expect(lines.count == 201)
        #expect(lines[199] == "line 200")
        #expect(lines[200] == "…（共 250 行，已省略 50 行）")
        let short = "a\nb\n"
        #expect(QuickActionsStore.cappedOutput(short) == short)
    }

    @Test func outputIsCappedByBytes() {
        let long = String(repeating: "x", count: 300)
        let out = QuickActionsStore.cappedOutput(long, maxBytes: 200)
        #expect(out.utf8.count <= 200)
        #expect(out.hasPrefix("xxx"))
        #expect(out.hasSuffix("字节）"))
        #expect(out.contains("共 300 字节"))
        #expect(QuickActionsStore.cappedOutput("abc", maxBytes: 200) == "abc")
    }

    @Test func joinedOutputSeparatesStreams() {
        #expect(QuickActionsStore.joinedOutput(stdout: "a", stderr: "b") == "a\nb")
        #expect(QuickActionsStore.joinedOutput(stdout: "a\n", stderr: "b") == "a\nb")
        #expect(QuickActionsStore.joinedOutput(stdout: "", stderr: "b") == "b")
        #expect(QuickActionsStore.joinedOutput(stdout: "a", stderr: "") == "a")
    }
}
