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
}
