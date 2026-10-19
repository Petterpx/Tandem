import AppKit
import DeviceCore
import SwiftUI

/// 日志窗口入口：按逻辑 id 取设备名与会话。出现时启动 `run`，窗口关闭时任务取消，logcat 随之停止。
struct LogWindowHost: View {
    let id: String
    let model: AppModel
    let services: AppServices

    @State private var session: LogSession?

    private var deviceName: String { (model.devices.first { $0.id == id } ?? model.lastKnownDevices[id])?.name ?? id }

    var body: some View {
        Group {
            if let session {
                LogWindowView(session: session, deviceName: deviceName, services: services)
            } else {
                Color.clear
            }
        }
        .navigationTitle("\(deviceName) 日志")
        .task {
            let s = services.logSession(for: id)
            session = s
            await s.run()
        }
        .onDisappear {
            if let session { services.releaseLogSession(id, session) }
            session = nil
        }
    }
}

/// 日志窗口（spec §3.6）：工具栏、列表、状态行。
struct LogWindowView: View {
    let session: LogSession
    let deviceName: String
    let services: AppServices

    /// 本窗口期间选过的包名（不持久化）。
    @State private var pinned: [String] = []
    @State private var readingForeground = false
    @State private var notice: String?
    @State private var follow = true

    private var deviceID: String { session.deviceID }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.separator).frame(height: 1)
            LogListView(session: session, follow: $follow)
            Rectangle().fill(Theme.separator).frame(height: 1)
            statusLine
        }
        .background(Theme.panel)
        .onAppear {
            if let p = session.target.package, !pinned.contains(p) { pinned.append(p) }
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 10) {
            targetMenu
            Picker("级别", selection: Bindable(session).minLevel) {
                ForEach(LogLevel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("最低级别")
            TextField("关键字", text: Bindable(session).keyword)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: 240)
            Spacer(minLength: 8)
            Button(session.paused ? "继续" : "暂停") { session.paused.toggle() }
            Button("清空") { session.clear() }
            Button("导出…") { export() }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var targetMenu: some View {
        Menu {
            Button { selectForeground() } label: { Text(foregroundTitle) }
            if !pinned.isEmpty {
                Divider()
                ForEach(pinned, id: \.self) { p in
                    Button { select(.package(p)) } label: { checked(p, session.target == .package(p)) }
                }
            }
            Divider()
            Button { select(.all) } label: { checked("全部", session.target == .all) }
        } label: {
            Text(targetTitle).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(readingForeground)
    }

    private var targetTitle: String { session.target.package ?? "全部" }

    /// 「前台 App（<包名>）」：包名取自快捷操作最近一次读到的前台 App；真正的包名在选择时再读一次。
    private var foregroundTitle: String {
        if case .success(let app)? = services.quickModel.foreground[deviceID], !app.package.isEmpty {
            return "前台 App（\(app.package)）"
        }
        return "前台 App"
    }

    @ViewBuilder
    private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// 切换目标：暂停时先继续，否则冻结的列表在新目标下是空的。
    private func select(_ target: LogTarget) {
        guard target != session.target else { return }
        notice = nil
        session.paused = false
        follow = true
        if let p = target.package, !pinned.contains(p) { pinned.append(p) }
        Task { await session.setTarget(target) }
    }

    /// 选择时读取一次前台包名并固定为目标，之后不随前台切换而变。
    private func selectForeground() {
        readingForeground = true
        notice = nil
        let id = deviceID
        Task {
            let result = await services.commands.readForegroundApp(id)
            readingForeground = false
            switch result {
            case .success(let app) where !app.package.isEmpty: select(.package(app.package))
            case .success: notice = "读不到前台 App"
            case .failure(let error): notice = QuickActionsModel.reason(error)
            }
        }
    }

    // MARK: 状态行

    private var statusLine: some View {
        HStack(spacing: 12) {
            if session.paused {
                Text("已暂停 · 新增 \(session.pendingCount) 条").foregroundStyle(Theme.warning)
            }
            if let message = session.status.message {
                Text(message).foregroundStyle(session.status == .disconnected ? Theme.danger : Theme.textSecondary)
            }
            if readingForeground { Text("正在读取前台 App…").foregroundStyle(Theme.textSecondary) }
            if let notice { Text(notice).foregroundStyle(Theme.danger) }
            Spacer()
            Text("\(session.visible.count) 行").foregroundStyle(Theme.textSecondary)
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    // MARK: 导出

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = LogExport.fileName(device: deviceName, target: session.target, date: Date())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try session.exportText().write(to: url, atomically: true, encoding: .utf8)
            notice = nil
        } catch {
            notice = "导出失败：\(error.localizedDescription)"
        }
    }
}

/// 日志列表：懒加载的等宽行，自动滚到最新；用户向上滚动后停止并显示「回到最新」。
private struct LogListView: View {
    let session: LogSession
    @Binding var follow: Bool

    private static let bottomID = "log-bottom"
    /// 自己触发滚动后的一小段时间里，底部哨兵的消失不算用户上滚。
    @State private var lastAutoScroll = ContinuousClock.now - .seconds(10)

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(session.visible) { LogRow(line: $0) }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                        .onAppear { follow = true }
                        .onDisappear {
                            if ContinuousClock.now - lastAutoScroll > .milliseconds(400) { follow = false }
                        }
                }
                .textSelection(.enabled)
                .padding(.vertical, 4)
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button("回到最新") { scrollToBottom(proxy) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(12)
                }
            }
            .onChange(of: session.visible.last?.id) {
                if follow { scrollToBottom(proxy) }
            }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        lastAutoScroll = .now
        follow = true
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
    }
}

/// 一行：时间、pid、级别（着色）、tag、内容；分隔行居中显示。
private struct LogRow: View {
    let line: LogLine

    var body: some View {
        switch line {
        case .entry(let e, _):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(e.time).foregroundStyle(Theme.textSecondary).frame(width: 108, alignment: .leading)
                Text(String(e.pid)).foregroundStyle(Theme.textSecondary).frame(width: 52, alignment: .trailing)
                Text(e.level.rawValue).foregroundStyle(Self.color(e.level)).fontWeight(.semibold)
                    .frame(width: 12)
                Text(e.tag).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.tail)
                    .frame(width: 140, alignment: .leading)
                Text(e.message).foregroundStyle(Self.color(e.level) == Theme.logVerbose ? Theme.textSecondary : Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 1)
        case .separator(let text, _):
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.warning)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
    }

    static func color(_ level: LogLevel) -> Color {
        switch level {
        case .verbose: Theme.logVerbose
        case .debug: Theme.logDebug
        case .info: Theme.logInfo
        case .warn: Theme.logWarn
        case .error: Theme.logError
        case .fatal: Theme.logFatal
        }
    }
}
