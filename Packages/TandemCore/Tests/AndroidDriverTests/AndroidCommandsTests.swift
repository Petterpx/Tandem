import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

@Suite struct AndroidCommandsTests {
    @Test func parsesNetworkSettings() {
        #expect(AndroidCommands.Network.parseState("1\n0\n0\n") == NetworkState(wifi: true, data: false, airplane: false))
        #expect(AndroidCommands.Network.parseState("2\nnull\n\n") == NetworkState(wifi: true, data: nil, airplane: nil))
    }

    @Test func setCommands() {
        #expect(AndroidCommands.Network.setCommand(.wifi, on: true) == "svc wifi enable")
        #expect(AndroidCommands.Network.setCommand(.data, on: false) == "svc data disable")
        #expect(AndroidCommands.Network.setCommand(.airplane, on: true) == "cmd connectivity airplane-mode enable")
    }

    /// 用真实 /bin/sh 验证转义后的参数原样回显。
    @Test func quoteNeutralizesInjection() throws {
        let input = "x'; reboot; echo '"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(ShellQuote.quote(input))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == input)
    }
}
