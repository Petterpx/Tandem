import SwiftUI

extension ActivitySource {
    var chipTitle: String { self == .ai ? "AI" : "你" }
    var chipTone: ChipTone { self == .ai ? .ai : .accent }
}

/// 操作记录的文案。
enum ActivityText {
    /// 「设备名 · 标题」，失败时在后面接「：原因」。
    static func line(_ e: ActivityEntry) -> String {
        let base = "\(e.deviceName) · \(e.title)"
        return e.failure.map { "\(base)：\($0)" } ?? base
    }
}

/// 底部「操作记录」：时间、来源（你 / AI）、「设备名 · 标题」；失败行用危险色并显示原因。
struct ActivityLogView: View {
    let log: ActivityLog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActivityLogHeader(isEmpty: log.entries.isEmpty) { log.clear() }
            if log.entries.isEmpty {
                Text("暂无操作记录")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView { ActivityRows(entries: log.entries) }
            }
        }
    }
}

/// 「操作记录」头部：高 38，标题后跟说明，尾部「清空」。
struct ActivityLogHeader: View {
    let isEmpty: Bool
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SectionHeader("操作记录").fixedSize()
            Text("你和 AI 的所有操作").tandemText(.meta).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button("清空", action: onClear)
                .buttonStyle(TandemButtonStyle(.link))
                .disabled(isEmpty)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

/// 记录行（ScrollView 里面的部分），单独拆出来供快照渲染。
struct ActivityRows: View {
    let entries: [ActivityEntry]

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(entries) { row($0) }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func row(_ e: ActivityEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: e.date))
                .tandemText(.monoMeta)
                .foregroundStyle(Theme.textSecondary)
            Chip(e.source.chipTitle, tone: e.source.chipTone)
            Text(ActivityText.line(e))
                .font(.system(size: 12))
                .foregroundStyle(e.failure == nil ? Theme.textPrimary : Theme.danger)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(ActivityText.line(e))
            Spacer(minLength: 0)
        }
    }
}
