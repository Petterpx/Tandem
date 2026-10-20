import DeviceCore
import SwiftUI

/// 传输进度条：显示该设备队列的首项，带「取消」；没有任务时不占位。
struct TransferProgressBar: View {
    let transfers: TransferQueue
    let deviceID: String

    var body: some View {
        let jobs = transfers.jobs(deviceID)
        if let first = jobs.first {
            TransferStrip(
                label: Self.label(first, remaining: jobs.count - 1),
                fraction: Self.fraction(first), percent: Self.percentText(first)
            ) { transfers.cancelCurrent(deviceID) }
        }
    }

    /// 0...1；总量未知、正在安装或尚未开始时为 nil（轨道不填充）。
    static func fraction(_ job: TransferJob) -> Double? {
        guard case .running(let p, let phase) = job.state, phase != "安装中", let total = p.total, total > 0 else { return nil }
        return min(1, Double(p.bytes) / Double(total))
    }

    /// `45%`；没有进度时为空字符串。
    static func percentText(_ job: TransferJob) -> String {
        fraction(job).map { "\(Int($0 * 100))%" } ?? ""
    }

    /// `推送 a.jpg · 还有 2 项`；安装为 `安装 app.apk · 推送中` / `安装中…`。百分比单独显示在右侧。
    static func label(_ job: TransferJob, remaining: Int) -> String {
        var parts = [job.kind.title]
        if case .running(_, let phase) = job.state, phase == "安装中" {
            parts.append("安装中…")
        } else if case .install = job.kind, fraction(job) != nil {
            parts.append("推送中")
        }
        if remaining > 0 { parts.append("还有 \(remaining) 项") }
        return parts.joined(separator: " · ")
    }
}

/// 进度条的展示部分：42 pt 高的白色条，标签、轨道、右对齐百分比与「取消」。
struct TransferStrip: View {
    let label: String
    let fraction: Double?
    let percent: String
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .layoutPriority(1)
            ProgressTrack(fraction: fraction).frame(minWidth: 80)
            Text(percent)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                .frame(width: 40, alignment: .trailing)
            Button("取消", action: onCancel).buttonStyle(TandemButtonStyle(.link))
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(Theme.windowBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
