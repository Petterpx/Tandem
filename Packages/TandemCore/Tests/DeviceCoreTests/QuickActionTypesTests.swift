import Foundation
import Testing
@testable import DeviceCore

@Test func packageNameValidation() throws {
    #expect(try PackageName.validate("com.demo.app_1") == "com.demo.app_1")
    for bad in ["demo", "com.demo;rm -rf /", "com..demo", "com.demo'", ""] {
        #expect(throws: DeviceError.self) { try PackageName.validate(bad) }
    }
}

@Test func packageNameErrorCode() {
    do {
        _ = try PackageName.validate("bad")
        Issue.record("应当抛错")
    } catch let error as DeviceError {
        #expect(error.code == .INVALID_ARGUMENT)
        #expect(error.message == "包名不合法：bad")
    } catch {
        Issue.record("错误类型不对")
    }
}

@Test func quoteWrapsAndEscapes() {
    #expect(ShellQuote.quote("a b") == "'a b'")
    #expect(ShellQuote.quote("it's") == #"'it'\''s'"#)
    #expect(ShellQuote.quote("") == "''")
}

@Test func networkStateSubscript() {
    let state = NetworkState(wifi: true, data: nil, airplane: false)
    #expect(state[.wifi] == true)
    #expect(state[.data] == nil)
    #expect(state[.airplane] == false)
}

private struct MinimalActions: DeviceActions {
    func screenshot() async throws -> Data { Data() }
    func uiTree() async throws -> UITree { UITree(screen: CGSize(width: 1, height: 1), elements: []) }
}

@Test func defaultImplementationsAreUnsupported() async {
    let actions = MinimalActions()
    do {
        _ = try await actions.networkState()
        Issue.record("应当抛错")
    } catch let error as DeviceError {
        #expect(error.code == .UNSUPPORTED)
    } catch {
        Issue.record("错误类型不对")
    }
    await #expect(throws: DeviceError.self) { try await actions.shell("ls", timeout: .seconds(1)) }
    await #expect(throws: DeviceError.self) { try await actions.launchApp("com.demo.app") }
}
