import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct AdbLocatorTests {
    let home = URL(fileURLWithPath: "/Users/test")
    let sdkAdb = "/Users/test/Library/Android/sdk/platform-tools/adb"
    let brokenAdb = "/usr/local/bin/adb"
    let bundledAdb = "/App/Vendor/adb"
    let okVersion = "Android Debug Bridge version 1.0.41\nVersion 33.0.3-8952118\n"

    func locator(_ runner: FakeProcessRunner, existing: Set<String>, environment: [String: String] = [:], bundled: URL? = nil) -> AdbLocator {
        AdbLocator(runner: runner, environment: environment, home: home, bundled: bundled, fileExists: { existing.contains($0) })
    }

    func stubShell(_ r: FakeProcessRunner, output: String) {
        r.stub("/bin/zsh", ["-lc", "command -v adb"], stdout: output)
    }

    @Test func skipsBrokenCandidate() async throws {
        let r = FakeProcessRunner()
        stubShell(r, output: brokenAdb + "\n")
        r.stubFailure(brokenAdb, ["version"], error: FakeProcessRunner.Unstubbed(description: "bad CPU type in executable"))
        r.stub(sdkAdb, ["version"], stdout: okVersion)
        let adb = try await locator(r, existing: [brokenAdb, sdkAdb]).locate()
        #expect(adb.url.path == home.path + "/Library/Android/sdk/platform-tools/adb")
        #expect(adb.version == "33.0.3-8952118")
    }

    @Test func fallsBackToBundled() async throws {
        let r = FakeProcessRunner()
        stubShell(r, output: "")
        r.stubFailure(brokenAdb, ["version"], error: FakeProcessRunner.Unstubbed(description: "bad CPU type"))
        r.stub(bundledAdb, ["version"], stdout: okVersion)
        let adb = try await locator(r, existing: [brokenAdb, bundledAdb], bundled: URL(fileURLWithPath: bundledAdb)).locate()
        #expect(adb.url.path == bundledAdb)
    }

    @Test func throwsAdbNotFoundWhenNothingRuns() async {
        let r = FakeProcessRunner()
        stubShell(r, output: "")
        r.stubFailure(brokenAdb, ["version"], error: FakeProcessRunner.Unstubbed(description: "bad CPU type"))
        await #expect(throws: DeviceError.adbNotFound()) {
            try await locator(r, existing: [brokenAdb]).locate()
        }
    }

    @Test func rejectsNonZeroExitAndWrongOutput() async throws {
        let r = FakeProcessRunner()
        stubShell(r, output: "")
        r.stub(sdkAdb, ["version"], stdout: okVersion, exitCode: 1)
        r.stub(brokenAdb, ["version"], stdout: "something else\n")
        await #expect(throws: DeviceError.adbNotFound()) {
            try await locator(r, existing: [sdkAdb, brokenAdb]).locate()
        }
    }

    @Test func candidateOrderDedupesAndFiltersMissing() async {
        let r = FakeProcessRunner()
        stubShell(r, output: "/opt/homebrew/bin/adb\n")
        let env = ["ANDROID_HOME": "/sdk-home", "ANDROID_SDK_ROOT": "/sdk-root"]
        let existing: Set<String> = [
            "/opt/homebrew/bin/adb", "/sdk-home/platform-tools/adb", "/sdk-root/platform-tools/adb",
            sdkAdb, "/usr/local/bin/adb", bundledAdb,
        ]
        let c = await locator(r, existing: existing, environment: env, bundled: URL(fileURLWithPath: bundledAdb)).candidates()
        #expect(c.map(\.path) == [
            "/opt/homebrew/bin/adb", "/sdk-home/platform-tools/adb", "/sdk-root/platform-tools/adb",
            sdkAdb, "/usr/local/bin/adb", bundledAdb,
        ])
        let missing = await locator(r, existing: ["/opt/homebrew/bin/adb"]).candidates()
        #expect(missing.map(\.path) == ["/opt/homebrew/bin/adb"])
    }

    @Test func clientPrependsSerial() async throws {
        let r = FakeProcessRunner()
        r.stub(sdkAdb, ["-s", "X", "get-state"], stdout: "device\n")
        let client = AdbClient(adb: Adb(url: URL(fileURLWithPath: sdkAdb), version: "1"), runner: r)
        _ = try await client.run(["get-state"], serial: "X")
        #expect(r.calls.last?.args == ["-s", "X", "get-state"])
    }

    @Test func getpropTrimsAndShellUsesShell() async throws {
        let r = FakeProcessRunner()
        r.stub(sdkAdb, ["-s", "X", "shell", "getprop", "ro.product.model"], stdout: "Pixel 7\r\n")
        let client = AdbClient(adb: Adb(url: URL(fileURLWithPath: sdkAdb), version: "1"), runner: r)
        #expect(try await client.getprop("X", "ro.product.model") == "Pixel 7")
    }
}
