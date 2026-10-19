import ControlProtocol
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ToolRegistryFilesTests {
    private static let fileNames = ["get_logs", "push_file", "pull_file", "install_app"]

    private static let device: DeviceInfo = {
        var d = AIEnv.pixel
        d.capabilities.formUnion([.apps, .logs, .files])
        return d
    }()

    private func text(_ r: ToolResult) -> String {
        guard case .text(let t) = r.content.first else { return "" }
        return t
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 创建指定大小的稀疏文件。
    private func makeFile(_ url: URL, bytes: Int64) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(bytes))
        try handle.close()
    }

    @Test func fileToolsListedAfterShell() {
        let e = AIEnv()
        let names = ToolRegistry(commands: e.commands).descriptors(for: []).map(\.name)
        withExtendedLifetime(e) {}
        #expect(Array(names.suffix(5)) == ["shell"] + Self.fileNames)
    }

    @Test func schemasMatchSpec() {
        let e = AIEnv()
        let schemas = Dictionary(
            uniqueKeysWithValues: ToolRegistry(commands: e.commands).descriptors(for: []).map { ($0.name, $0) })
        withExtendedLifetime(e) {}
        #expect(schemas["get_logs"]?.inputSchema["required"] == [])
        #expect(schemas["get_logs"]?.inputSchema["properties"]?["level"]?["enum"] == ["V", "D", "I", "W", "E", "F"])
        #expect(schemas["push_file"]?.inputSchema["required"] == ["path"])
        #expect(schemas["pull_file"]?.inputSchema["required"] == ["path"])
        #expect(schemas["install_app"]?.inputSchema["required"] == ["path"])
        // pull_file 只拉取普通文件：说明里不能承诺文件夹
        let pull = schemas["pull_file"]?.description ?? ""
        #expect(pull.contains("不支持文件夹"))
        #expect(!pull.contains("文件或文件夹"))
    }

    @Test func logsArgumentsValidated() async throws {
        let actions = RecordingActions()
        let e = AIEnv(devices: [Self.device], actions: actions, hasSession: false, sleep: { _ in })
        let r = ToolRegistry(commands: e.commands)
        let cases: [[String: JSONValue]] = [
            ["lines": 0], ["lines": 3000], ["lines": -1], ["lines": "10"], ["level": "X"], ["level": "v"], ["level": 1],
            ["app": ""], ["grep": ""],
        ]
        for args in cases {
            let result = try await r.call("get_logs", arguments: args)
            #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"), "\(args) → \(text(result))")
        }
        withExtendedLifetime(e) {}
        #expect(actions.calls.isEmpty)
    }

    @Test func pathsRequired() async throws {
        let e = AIEnv(devices: [Self.device], actions: RecordingActions(), hasSession: false, sleep: { _ in })
        let r = ToolRegistry(commands: e.commands)
        for name in ["push_file", "pull_file", "install_app"] {
            for args: [String: JSONValue] in [[:], ["path": ""], ["path": 1]] {
                let result = try await r.call(name, arguments: args)
                #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"), "\(name) \(args)")
            }
        }
        withExtendedLifetime(e) {}
    }

    @Test func transferTimeoutScalesWithSize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mb: Int64 = 1024 * 1024
        let file = dir.appendingPathComponent("a.bin")
        try makeFile(file, bytes: 25 * mb)
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string(file.path)]) == .seconds(60))
        #expect(ToolRegistry.timeout(for: "install_app", arguments: ["path": .string(file.path)]) == .seconds(60))
        let exact = dir.appendingPathComponent("exact.bin")
        try makeFile(exact, bytes: 10 * mb)
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string(exact.path)]) == .seconds(40))
        let huge = dir.appendingPathComponent("huge.bin")
        try makeFile(huge, bytes: 10 * 1024 * mb)
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string(huge.path)]) == .seconds(600))
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string("/nonexistent/\(UUID().uuidString)")]) == .seconds(30))
        #expect(ToolRegistry.timeout(for: "push_file", arguments: [:]) == .seconds(30))
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": 5]) == .seconds(30))
        #expect(ToolRegistry.timeout(for: "pull_file", arguments: [:]) == .seconds(600))
        #expect(ToolRegistry.timeout(for: "get_logs", arguments: [:]) == .seconds(30))
    }

    @Test func folderSizeIsRecursiveAndSkipsSymlinks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let mb: Int64 = 1024 * 1024
        let sub = dir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try makeFile(dir.appendingPathComponent("a.bin"), bytes: 8 * mb)
        try makeFile(sub.appendingPathComponent("b.bin"), bytes: 8 * mb)
        // 指回上级的符号链接不会造成环，也不重复计大小
        try FileManager.default.createSymbolicLink(at: sub.appendingPathComponent("loop"), withDestinationURL: dir)
        #expect(ToolRegistry.localSize(dir.path) == 16 * mb)
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string(dir.path)]) == .seconds(50))
    }

    @Test func folderWalkStopsOnceCapReached() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try makeFile(dir.appendingPathComponent("big.bin"), bytes: 600 * 1024 * 1024)
        for i in 0..<20 { try makeFile(dir.appendingPathComponent("f\(i)"), bytes: 0) }
        #expect(ToolRegistry.timeout(for: "push_file", arguments: ["path": .string(dir.path)]) == .seconds(600))
        #expect((ToolRegistry.localSize(dir.path) ?? 0) >= 57 * 10 * 1024 * 1024)
    }

    @Test func folderWalkEntryCapYieldsMaxTimeout() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<10 { try makeFile(dir.appendingPathComponent("f\(i)"), bytes: 0) }
        let args: [String: JSONValue] = ["path": .string(dir.path)]
        #expect(ToolRegistry.transferTimeout(arguments: args, entryCap: 5) == .seconds(600))
        #expect(ToolRegistry.transferTimeout(arguments: args, entryCap: 10) == .seconds(30))
    }

    @Test func capabilitiesFilterTools() {
        let e = AIEnv()
        let r = ToolRegistry(commands: e.commands)
        var d = AIEnv.pixel
        d.capabilities = [.logs]
        #expect(r.descriptors(for: [d]).map(\.name) == ["list_devices", "get_logs"])
        d.capabilities = [.files]
        #expect(r.descriptors(for: [d]).map(\.name) == ["list_devices", "push_file", "pull_file"])
        d.capabilities = [.apps]
        #expect(r.descriptors(for: [d]).map(\.name).contains("install_app"))
        d.capabilities = [.touch]
        #expect(r.descriptors(for: [d]).map(\.name).filter(Self.fileNames.contains).isEmpty)
        withExtendedLifetime(e) {}
    }

    @Test func unsupportedDeviceRejectsFileTools() async throws {
        let e = AIEnv(devices: [AIEnv.pixel], actions: RecordingActions(), hasSession: false, sleep: { _ in })
        let r = ToolRegistry(commands: e.commands)
        let result = try await r.call("push_file", arguments: ["path": "/tmp/x"])
        withExtendedLifetime(e) {}
        #expect(result.isError && text(result).hasPrefix("UNSUPPORTED:"))
    }
}
