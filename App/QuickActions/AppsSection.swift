import DeviceCore
import SwiftUI

/// 应用分段（spec §3.4）：目标下拉（「前台 App」加已固定的包名）、前台 App 信息与「📌 固定」、五个操作按钮。
struct AppsSection: View {
    let model: QuickActionsModel
    let deviceID: String
    /// 打开该设备的日志窗口，参数为初始目标。
    let openLogs: (LogTarget) -> Void

    /// 待确认的卸载：发起时的设备与包名，确认期间切换设备或目标也不会卸错。
    @State private var uninstallPending: (id: String, package: String)?

    private var busy: Bool { model.isBusy(deviceID, .apps) }
    private var package: String? { model.targetPackage(deviceID) }

    /// 按钮不可用的原因；有目标包名时为 nil。
    private var unavailableReason: String? {
        guard package == nil else { return nil }
        if model.isReadingForeground(deviceID) { return "正在读取前台 App" }
        if case .failure(let error)? = model.foreground[deviceID] { return QuickActionsModel.reason(error) }
        return "读不到前台 App"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                targetPicker
                foregroundRow
                buttons
            }
            .tandemCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            if model.commands.can(.apps, deviceID) || model.commands.can(.files, deviceID) {
                ApkDropZone(
                    canInstall: model.commands.can(.apps, deviceID), canPush: model.commands.can(.files, deviceID),
                    onFiles: { [commands = model.commands, deviceID] in _ = commands.pushFiles(deviceID, $0, origin: .workspace) })
            }
            logsButton
        }
        .alert(
            "卸载 \(uninstallPending?.package ?? "")？",
            isPresented: Binding(get: { uninstallPending != nil }, set: { if !$0 { uninstallPending = nil } }),
            presenting: uninstallPending
        ) { pending in
            Button("卸载", role: .destructive) { run(.uninstall, id: pending.id, package: pending.package) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("卸载后应用数据不可恢复")
        }
        // 切换设备时收起上一台设备的确认框
        .onChange(of: deviceID) { uninstallPending = nil }
    }

    // MARK: 目标

    private var targetPicker: some View {
        HStack {
            Text("目标").tandemText(.meta).foregroundStyle(Theme.textSecondary)
            Menu {
                Button { select(.foreground) } label: { checked("前台 App", model.currentTarget(deviceID) == .foreground) }
                if !model.store.pinnedPackages.isEmpty {
                    Divider()
                    ForEach(model.store.pinnedPackages, id: \.self) { p in
                        Button { select(.pinned(p)) } label: { checked(p, model.currentTarget(deviceID) == .pinned(p)) }
                    }
                    Divider()
                    Menu("移除固定") {
                        ForEach(model.store.pinnedPackages, id: \.self) { p in
                            Button(p) { Task { await model.unpin(p) } }
                        }
                    }
                }
            } label: {
                Text(targetTitle).tandemText(.body).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var targetTitle: String {
        switch model.currentTarget(deviceID) {
        case .foreground: "前台 App"
        case .pinned(let p): p
        }
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func select(_ t: AppTarget) {
        let id = deviceID
        Task { await model.setTarget(id, t) }
    }

    // MARK: 前台 App

    private var foregroundRow: some View {
        HStack(spacing: 6) {
            Text("当前前台").tandemText(.meta).foregroundStyle(Theme.textSecondary)
            switch model.foreground[deviceID] {
            case .success(let app)?:
                Text(app.package)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if let version = app.versionName {
                    Text(version).tandemText(.meta).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if model.isReadingForeground(deviceID) { ProgressView().controlSize(.small) }
                Button("固定") { model.pinForeground(deviceID) }
                    .buttonStyle(TandemButtonStyle(.link))
                    .disabled(model.store.pinnedPackages.contains(app.package) || model.isReadingForeground(deviceID))
            case .failure(let error)?:
                UnreadableMark(reason: QuickActionsModel.reason(error))
                Spacer()
            case nil:
                UnreadableMark(reason: "尚未读取")
                Spacer()
            }
        }
    }

    // MARK: 操作

    private var buttons: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
            ForEach([AppAction.launch, .forceStop, .clearData, .restart], id: \.self) { action in
                Button {
                    if let package { run(action, id: deviceID, package: package) }
                } label: {
                    Text(action.verb).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
                }
            }
            Button {
                if let package { uninstallPending = (deviceID, package) }
            } label: {
                Text(AppAction.uninstall.verb).lineLimit(1).minimumScaleFactor(0.7).frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(TandemButtonStyle(.secondary))
        .disabled(package == nil || busy)
        .help(ifPresent: unavailableReason)
    }

    /// 日志不依赖目标包名：没有目标时看全部日志。
    private var logsButton: some View {
        Button("查看日志") { openLogs(package.map(LogTarget.package) ?? .all) }
            .buttonStyle(TandemButtonStyle(.link))
            .disabled(!model.commands.can(.logs, deviceID))
            .help(ifPresent: model.commands.can(.logs, deviceID) ? nil : "设备不支持读取日志")
    }

    private func run(_ action: AppAction, id: String, package: String) {
        Task { await model.appAction(id, action, package: package) }
    }
}
