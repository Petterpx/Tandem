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
            Rectangle().fill(Theme.border).frame(height: 1)
            LogListView(session: session, follow: $follow)
            Rectangle().fill(Theme.border).frame(height: 1)
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

/// 日志列表：NSTableView（固定行高，只创建可见行），自动滚到最新；用户向上滚动后停止并显示「回到最新」。
private struct LogListView: View {
    let session: LogSession
    @Binding var follow: Bool

    @State private var scrollToLatest = 0

    var body: some View {
        LogTableView(lines: session.visible, follow: $follow, scrollRequest: scrollToLatest)
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button("回到最新") {
                        follow = true
                        scrollToLatest += 1
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(12)
                }
            }
    }
}

/// 支持 ⌘C 的表格。
private final class LogNSTableView: NSTableView {
    var onCopy: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopy?() }
}

private struct LogTableView: NSViewRepresentable {
    let lines: [LogLine]
    @Binding var follow: Bool
    let scrollRequest: Int

    static let rowHeight: CGFloat = 16
    static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let c = context.coordinator
        let table = LogNSTableView()
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = NSColor(Theme.panel)
        table.headerView = nil
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.font]
        func width(_ sample: String) -> CGFloat { ceil((sample as NSString).size(withAttributes: attrs).width) + 12 }
        for (id, w, resizable) in [
            ("time", width("00-00 00:00:00.000"), false), ("pid", width("0000000"), false),
            ("level", width("W"), false), ("tag", 150, true), ("message", 400, true),
        ] as [(String, CGFloat, Bool)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.width = w
            col.minWidth = id == "message" ? 100 : w
            if !resizable { col.maxWidth = w }
            table.addTableColumn(col)
        }
        table.dataSource = c
        table.delegate = c
        table.onCopy = { [weak c] in c?.copySelection() }
        c.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Theme.panel)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            c, selector: #selector(Coordinator.boundsChanged), name: NSView.boundsDidChangeNotification,
            object: scroll.contentView)
        c.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.setFollow = { follow = $0 }
        let changed = c.lines != lines
        if changed {
            c.lines = lines
            c.table?.reloadData()
        }
        let requested = c.lastScrollRequest != scrollRequest
        c.lastScrollRequest = scrollRequest
        if follow && (changed || requested) { c.scrollToBottom() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var lines: [LogLine] = []
        weak var table: LogNSTableView?
        weak var scroll: NSScrollView?
        var setFollow: (Bool) -> Void = { _ in }
        var lastScrollRequest = 0
        private var programmatic = false

        func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .separator = lines[row] { return true }
            return false
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let line = lines[row]
            let text: String, color: NSColor, tip: String?
            var alignment = NSTextAlignment.left
            switch line {
            case .separator(let s, _):
                // 分隔行是组行（tableColumn 为 nil），横跨整行
                return field(tableView, "separator", s, NSColor(Theme.warning), alignment: .center, tip: nil)
            case .entry(let e, _):
                let id = tableColumn?.identifier.rawValue ?? ""
                tip = nil
                switch id {
                case "time": text = e.time; color = NSColor(Theme.textSecondary)
                case "pid": text = String(e.pid); color = NSColor(Theme.textSecondary); alignment = .right
                case "level": text = e.level.rawValue; color = NSColor(LogRow.color(e.level))
                case "tag": text = e.tag; color = NSColor(Theme.textPrimary)
                default:
                    text = e.message
                    color = e.level == .verbose ? NSColor(Theme.textSecondary) : NSColor(Theme.textPrimary)
                    return field(tableView, id, text, color, alignment: alignment, tip: e.message)
                }
                return field(tableView, id, text, color, alignment: alignment, tip: id == "tag" ? e.tag : nil)
            }
        }

        private func field(_ table: NSTableView, _ id: String, _ text: String, _ color: NSColor,
                           alignment: NSTextAlignment, tip: String?) -> NSTextField {
            let key = NSUserInterfaceItemIdentifier("log-\(id)")
            let f = (table.makeView(withIdentifier: key, owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = key
                f.font = LogTableView.font
                f.lineBreakMode = .byTruncatingTail
                f.maximumNumberOfLines = 1
                f.cell?.usesSingleLineMode = true
                return f
            }()
            f.stringValue = text
            f.textColor = color
            f.alignment = alignment
            f.toolTip = tip
            return f
        }

        // MARK: 跟随

        func scrollToBottom() {
            guard let scroll, let table, !lines.isEmpty else { return }
            programmatic = true
            table.scrollRowToVisible(lines.count - 1)
            scroll.reflectScrolledClipView(scroll.contentView)
            programmatic = false
        }

        @objc func boundsChanged() {
            guard !programmatic, let scroll, let doc = scroll.documentView else { return }
            let atBottom = LogExport.isAtBottom(
                contentHeight: doc.frame.height, visibleMaxY: scroll.contentView.bounds.maxY,
                rowHeight: LogTableView.rowHeight)
            setFollow(atBottom)
        }

        // MARK: 复制

        func copySelection() {
            guard let table else { return }
            let selected = table.selectedRowIndexes.filter { $0 < lines.count }.map { lines[$0] }
            guard !selected.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(LogExport.text(selected), forType: .string)
        }
    }
}

/// 级别颜色。
private enum LogRow {
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
