import Foundation
import DeviceCore

extension AndroidActions {
    public func networkState() async throws -> NetworkState {
        AndroidCommands.Network.parseState(try await shellChecked(AndroidCommands.Network.readCommand).stdout)
    }

    public func setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState {
        if kind == .airplane, try await sdkLevel() < 30 {
            throw DeviceError.unsupported("该系统版本不支持通过 shell 切换飞行模式")
        }
        _ = try await shellChecked(AndroidCommands.Network.setCommand(kind, on: on))
        try await Task.sleep(for: settleDelay)
        let state = try await networkState()
        guard state[kind] == on else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "设置未生效", suggestion: "部分 ROM 禁止通过 shell 修改此项，请在手机上手动设置")
        }
        return state
    }
}
