import Testing
import Foundation
@testable import Tandem

@Suite struct ClaudeSetupTests {
    @Test func quotesPathWithSpacesAndQuote() {
        #expect(ClaudeSetup.addCommand(mcpPath: "/a b/it's/tandem-mcp") == #"claude mcp add --scope user tandem -- '/a b/it'\''s/tandem-mcp'"#)
    }

    @Test func shellQuoteWrapsPlainPath() {
        #expect(ClaudeSetup.shellQuote("/x/tandem-mcp") == "'/x/tandem-mcp'")
        #expect(ClaudeSetup.shellQuote("''") == #"''\'''\'''"#)
    }

    @Test func installRemovesFirst() {
        let path = "/Applications/Tandem.app/Contents/MacOS/tandem-mcp"
        let script = ClaudeSetup.installScript(mcpPath: path)
        #expect(script.hasPrefix("claude mcp remove --scope user tandem"))
        #expect(script.hasSuffix(ClaudeSetup.addCommand(mcpPath: path)))
        #expect(script == "claude mcp remove --scope user tandem >/dev/null 2>&1; " + ClaudeSetup.addCommand(mcpPath: path))
    }

    @Test func jsonConfigEscapes() throws {
        let path = #"/odd "dir"\x/tandem-mcp"#
        let json = ClaudeSetup.jsonConfig(mcpPath: path)
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let servers = object?["mcpServers"] as? [String: Any]
        let tandem = servers?["tandem"] as? [String: Any]
        #expect(tandem?["command"] as? String == path)
        // 带缩进，便于阅读与粘贴
        #expect(json.contains("\n"))
    }

    @Test func runTimesOutAndTerminates() async {
        let start = ContinuousClock.now
        let r = await ClaudeSetup.run(executable: "/bin/sleep", arguments: ["5"], timeout: .milliseconds(200))
        #expect(!r.ok && r.output.contains("超时"))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func runDoesNotWaitForInput() async {
        // 标准输入是 /dev/null：等输入的命令立即读到 EOF，不会挂起
        let r = await ClaudeSetup.run(executable: "/bin/cat", arguments: [], timeout: .seconds(5))
        #expect(r.ok && r.output.isEmpty)
    }

    @Test func runCombinesOutputAndStatus() async {
        let r = await ClaudeSetup.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"],
                                      timeout: .seconds(5))
        #expect(!r.ok && r.output.contains("out") && r.output.contains("err"))
    }
}
