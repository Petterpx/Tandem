import DeviceCore
import SwiftUI

/// 网络分段（spec §3.3）：Wi-Fi、移动数据、飞行模式三个开关，均绑定回读值；切换中显示进度。
struct NetworkSection: View {
    let model: QuickActionsModel
    let deviceID: String

    /// 经 Wi-Fi 调试时会断开连接、待确认的操作（关闭 Wi-Fi / 开启飞行模式）。
    /// 记下发起时的设备，确认期间切换设备也不会改错。
    private struct Pending {
        var id: String
        var kind: NetworkKind
        var on: Bool
        var message: String

        /// 确认按钮文字。
        var action: String { kind == .airplane ? "开启飞行模式" : "关闭 Wi-Fi" }
    }

    @State private var pending: Pending?

    private var busy: Bool { model.isBusy(deviceID, .network) }

    /// 没有要恢复的项（含读不到状态）或正在执行时禁用。
    private var resetDisabled: Bool {
        busy || DeviceCommands.resetNetworkSteps(try? model.network[deviceID]?.get()).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                ForEach(Array(NetworkKind.allCases.enumerated()), id: \.element) { index, kind in
                    if index > 0 { CardDivider() }
                    row(kind)
                }
            }
            .tandemCard()
            Button("恢复默认网络") { Task { await model.resetNetwork(deviceID) } }
                .buttonStyle(TandemButtonStyle(.secondary))
                .disabled(resetDisabled)
        }
        .confirmationDialog(
            pending?.message ?? "",
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
            titleVisibility: .visible, presenting: pending
        ) { p in
            Button(p.action, role: .destructive) { set(p.id, p.kind, on: p.on) }
            Button("取消", role: .cancel) {}
        }
        // 切换设备时收起上一台设备的确认框
        .onChange(of: deviceID) { pending = nil }
    }

    private func row(_ kind: NetworkKind) -> some View {
        CardRow(kind.title) {
            HStack(spacing: 8) {
                if busy { ProgressView().controlSize(.small) }
                switch model.network[deviceID] {
                case .success(let state)?:
                    if let on = state[kind] {
                        Toggle(kind.title, isOn: Binding(get: { on }, set: { toggle(kind, on: $0) }))
                            .labelsHidden()
                            .toggleStyle(TandemSwitchStyle())
                            .disabled(busy)
                    } else {
                        UnreadableMark(reason: "读不到当前状态")
                    }
                case .failure(let error)?:
                    UnreadableMark(reason: QuickActionsModel.reason(error))
                case nil:
                    UnreadableMark(reason: "尚未读取")
                }
            }
        }
    }

    private func toggle(_ kind: NetworkKind, on: Bool) {
        if let device = model.commands.device(deviceID),
           let message = DeviceCommands.wifiConfirmation(device, kind: kind, on: on) {
            pending = Pending(id: deviceID, kind: kind, on: on, message: message)
        } else {
            set(deviceID, kind, on: on)
        }
    }

    private func set(_ id: String, _ kind: NetworkKind, on: Bool) {
        Task { await model.setNetwork(id, kind, on: on) }
    }
}

extension NetworkKind {
    var title: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .data: "移动数据"
        case .airplane: "飞行模式"
        }
    }
}
