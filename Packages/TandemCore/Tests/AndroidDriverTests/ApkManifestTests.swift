import Foundation
import Testing
@testable import AndroidDriver

struct ApkManifestTests {
    @Test func readsPackageFromFixture() async throws {
        let url = try #require(Bundle.module.url(forResource: "tandem-test", withExtension: "apk", subdirectory: "Fixtures"))
        let name = await ApkManifest.packageName(apk: url, runner: SystemProcessRunner())
        #expect(name == "dev.tandem.testapp")
    }

    @Test func garbageReturnsNil() async throws {
        #expect(ApkManifest.packageName(Data()) == nil)
        #expect(ApkManifest.packageName(Data((0..<4096).map { _ in UInt8.random(in: 0...255) })) == nil)
        // 合法文件头后跟垃圾
        #expect(ApkManifest.packageName(Data([3, 0, 8, 0, 0xFF, 0xFF, 0xFF, 0x7F] + [UInt8](repeating: 0xFF, count: 64))) == nil)
    }

    @Test func truncatedManifestReturnsNil() async throws {
        let url = try #require(Bundle.module.url(forResource: "tandem-test", withExtension: "apk", subdirectory: "Fixtures"))
        let r = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, "AndroidManifest.xml"], timeout: .seconds(10))
        #expect(ApkManifest.packageName(r.stdout) == "dev.tandem.testapp")
        // 每个截断长度都不能崩溃，也不能得到包名
        for n in 0..<r.stdout.count { #expect(ApkManifest.packageName(r.stdout.prefix(n)) == nil) }
    }

    @Test func missingApkReturnsNil() async {
        let name = await ApkManifest.packageName(apk: URL(fileURLWithPath: "/nonexistent.apk"), runner: SystemProcessRunner())
        #expect(name == nil)
    }

    private func fixtureManifest() async throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "tandem-test", withExtension: "apk", subdirectory: "Fixtures"))
        let r = try await SystemProcessRunner().run(URL(fileURLWithPath: "/usr/bin/unzip"), ["-p", url.path, "AndroidManifest.xml"], timeout: .seconds(10))
        return r.stdout
    }

    /// 固定种子的变异：保持头部合法，让解析走到字符串池与属性代码；只要不崩溃即可。
    @Test func mutatedManifestNeverCrashes() async throws {
        let original = [UInt8](try await fixtureManifest())
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<600 {
            var bytes = original
            for _ in 0..<Int.random(in: 1...4, using: &rng) {
                let i = Int.random(in: 8..<bytes.count, using: &rng)
                if Bool.random(using: &rng) { bytes[i] ^= UInt8(1 << Int.random(in: 0..<8, using: &rng)) }
                else { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
            }
            let result: String? = ApkManifest.packageName(Data(bytes))
            _ = result
        }
    }

    @Test func hostileChunkFieldsReturnNil() async throws {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func file(_ body: [UInt8]) -> Data {
            Data([3, 0, 8, 0] + le32(UInt32(8 + body.count)) + body)
        }
        // 零大小分块
        #expect(ApkManifest.packageName(file([1, 0, 8, 0] + le32(0))) == nil)
        // 字符串池：count / stringsStart 巨大
        var pool = [1, 0, 28, 0] + le32(40) + le32(0xFFFF_FFFF) + le32(0) + le32(0x100) + le32(0xFFFF_FFF0) + le32(0)
        pool += [UInt8](repeating: 0xFF, count: 12)
        #expect(ApkManifest.packageName(file(pool)) == nil)
        // 合法的小字符串池 + attributeCount / attributeStart 巨大的起始元素
        let strPool = [1, 0, 28, 0] + le32(40) + le32(1) + le32(0) + le32(0x100) + le32(32) + le32(0)
            + le32(0) + [8, 8] + Array("manifest".utf8) + [0, 0, 0]
        let elem = [2, 1, 16, 0] + le32(36) + le32(1) + le32(0xFFFF_FFFF) + le32(0xFFFF_FFFF) + le32(0)
            + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(ApkManifest.packageName(file(strPool + elem)) == nil)
        // 同一长字符串被大量索引引用也不放大内存
        let many = [1, 0, 28, 0] + le32(28 + 4 * 1000) + le32(1000) + le32(0) + le32(0x100) + le32(28 + 4000) + le32(0)
            + [UInt8](repeating: 0, count: 4000)
        #expect(ApkManifest.packageName(file(many)) == nil)
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
