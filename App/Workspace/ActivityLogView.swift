import SwiftUI

/// 底部「操作记录」：时间、来源（你 / AI）、设备名、标题；失败行用危险色并显示原因。
struct ActivityLogView: View {
    let log: ActivityLog

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("操作记录").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("清空") { log.clear() }
                    .buttonStyle(.borderless).font(.caption)
                    .foregroundStyle(Theme.accent)
                    .disabled(log.entries.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if log.entries.isEmpty {
                Text("暂无操作记录").font(.callout).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(log.entries) { row($0) }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
            }
        }
    }

    private func row(_ e: ActivityEntry) -> some View {
        let failed = e.failure != nil
        let color = failed ? Theme.danger : Theme.textPrimary
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: e.date)).monospacedDigit().foregroundStyle(Theme.textSecondary)
            Text(e.source == .ai ? "AI" : "你")
                .font(.caption2.weight(.medium))
                .foregroundStyle(e.source == .ai ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 5)
                .background((e.source == .ai ? Theme.accent : Theme.textSecondary).opacity(0.12), in: Capsule())
            Text(e.deviceName).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Text(e.failure.map { "\(e.title)：\($0)" } ?? e.title)
                .foregroundStyle(color).lineLimit(2)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
