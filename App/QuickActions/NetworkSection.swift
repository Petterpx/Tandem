import DeviceCore
import SwiftUI

/// 网络分段（spec §3.3）：Wi-Fi、移动数据、飞行模式三个开关，均绑定回读值；切换中显示进度。
struct NetworkSection: View {
    let model: QuickActionsModel
    let deviceID: String

    /// 待确认「关闭 Wi-Fi」的设备 id（经 Wi-Fi 调试）；记下发起时的设备，确认期间切换设备也不会关错。
    @State private var wifiOffPending: String?

    private var busy: Bool { model.isBusy(deviceID, .network) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(NetworkKind.allCases, id: \.self) { kind in
                row(kind)
            }
        }
        .font(.callout)
        .confirmationDialog(
            "关闭 Wi-Fi 会断开与设备的无线调试连接",
            isPresented: Binding(get: { wifiOffPending != nil }, set: { if !$0 { wifiOffPending = nil } }),
            titleVisibility: .visible, presenting: wifiOffPending
        ) { id in
            Button("关闭 Wi-Fi", role: .destructive) { set(id, .wifi, on: false) }
            Button("取消", role: .cancel) {}
        }
    }

    private func row(_ kind: NetworkKind) -> some View {
        HStack {
            Text(kind.title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            switch model.network[deviceID] {
            case .success(let state)?:
                if let on = state[kind] {
                    Toggle(kind.title, isOn: Binding(get: { on }, set: { toggle(kind, on: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
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

    private func toggle(_ kind: NetworkKind, on: Bool) {
        if let device = model.commands.device(deviceID),
           DeviceCommands.needsWifiConfirmation(device, kind: kind, on: on) {
            wifiOffPending = deviceID
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
