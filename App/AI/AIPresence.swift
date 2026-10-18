import DeviceCore
import Foundation
import Observation

/// 镜像窗口上叠加的 AI 操作提示。
struct AIIndicator: Identifiable, Equatable {
    enum Kind: Equatable {
        case tap(NormalizedPoint)
        case longPress(NormalizedPoint, seconds: Double)
        case swipe(NormalizedPoint, NormalizedPoint)
        /// 只显示顶部提示
        case label
    }

    let id: UUID
    let kind: Kind
    let label: String
}

/// AI 的在场状态：每台设备最近一条操作提示（一般 2 秒后消失）与最近使用时间。
@MainActor @Observable
final class AIPresence {
    static let indicatorDuration: Duration = .seconds(2)

    private(set) var indicators: [String: AIIndicator] = [:]
    @ObservationIgnored private(set) var lastUsed: [String: Date] = [:]
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 提示显示多久：一般 2 秒；长按要覆盖整个按住时间再加 0.6 秒淡出。
    static func lifetime(_ kind: AIIndicator.Kind) -> Duration {
        guard case .longPress(_, let seconds) = kind else { return indicatorDuration }
        return max(indicatorDuration, .milliseconds(Int((seconds * 1000).rounded()) + 600))
    }

    func touch(_ id: String) { lastUsed[id] = now() }

    /// 替换该设备的提示；到期（lifetime）后若仍是同一条才移除，避免旧计时器误关新提示。
    func show(_ id: String, _ kind: AIIndicator.Kind, label: String) {
        let indicator = AIIndicator(id: UUID(), kind: kind, label: label)
        indicators[id] = indicator
        Task { [weak self] in
            try? await Task.sleep(for: Self.lifetime(kind))
            guard let self, self.indicators[id]?.id == indicator.id else { return }
            self.indicators[id] = nil
        }
    }

    func clearIndicator(_ id: String) { indicators[id] = nil }
}
