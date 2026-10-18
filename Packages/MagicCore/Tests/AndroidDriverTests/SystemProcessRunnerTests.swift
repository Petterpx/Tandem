import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct SystemProcessRunnerTests {
    let runner = SystemProcessRunner()

    @Test func runsAndCapturesOutput() async throws {
        let r = try await runner.run(URL(fileURLWithPath: "/bin/echo"), ["hi"], timeout: .seconds(3))
        #expect(r.exitCode == 0)
        #expect(r.stdoutString == "hi\n")
    }

    @Test func timeoutTerminatesAndThrows() async {
        await #expect(throws: DeviceError.self) {
            try await runner.run(URL(fileURLWithPath: "/bin/sleep"), ["5"], timeout: .milliseconds(200))
        }
    }

    @Test func launchFailureThrowsInsteadOfCrashing() async {
        await #expect(throws: (any Error).self) {
            try await runner.run(URL(fileURLWithPath: "/nonexistent/adb"), ["version"], timeout: .seconds(1))
        }
    }

    @Test func streamEmitsLines() async throws {
        let p = try runner.stream(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo a; echo b >&2; printf c"])
        var got: [String] = []
        for await l in p.lines { got.append(l) }
        #expect(Set(got) == ["a", "b", "c"])
    }
}
