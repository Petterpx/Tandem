import DeviceCore
import SwiftUI

/// 镜像画面底部的传输进度栏：显示该设备队列的首项，带「取消」。
struct TransferProgressBar: View {
    let transfers: TransferQueue
    let deviceID: String

    var body: some View {
        let jobs = transfers.jobs(deviceID)
        if let first = jobs.first {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.label(first, remaining: jobs.count - 1))
                        .font(.caption).foregroundStyle(Theme.onVideo).lineLimit(1).truncationMode(.middle)
                    if let fraction = Self.fraction(first) {
                        ProgressView(value: fraction).progressViewStyle(.linear).tint(Theme.accent)
                    } else {
                        ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                    }
                }
                Button("取消") { transfers.cancelCurrent(deviceID) }
                    .buttonStyle(.borderless).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.videoScrim)
        }
    }

    /// 0...1；总量未知、正在安装或尚未开始时为 nil（显示不定进度）。
    static func fraction(_ job: TransferJob) -> Double? {
        guard case .running(let p, let phase) = job.state, phase != "安装中", let total = p.total, total > 0 else { return nil }
        return min(1, Double(p.bytes) / Double(total))
    }

    /// `推送 a.jpg · 45% · 还有 2 项`；安装为 `安装 app.apk · 推送中 80%` / `安装中…`。
    static func label(_ job: TransferJob, remaining: Int) -> String {
        var parts = [job.kind.title]
        let percent = fraction(job).map { "\(Int($0 * 100))%" }
        if case .running(_, let phase) = job.state, phase == "安装中" {
            parts.append("安装中…")
        } else if case .install = job.kind {
            if let percent { parts.append("推送中 \(percent)") }
        } else if let percent {
            parts.append(percent)
        }
        if remaining > 0 { parts.append("还有 \(remaining) 项") }
        return parts.joined(separator: " · ")
    }
}
