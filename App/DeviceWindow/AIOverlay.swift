import DeviceCore
import SwiftUI

/// 投屏画面上的 AI 操作提示（spec §5.2）：落点涟漪、长按圆环、滑动轨迹与顶部胶囊。
/// 只观察 AIPresence，不接收点击；归一化坐标经 ViewGeometry 换算到视频在视图内的矩形。
struct AIOverlay: View {
    let presence: AIPresence
    let deviceID: String
    let videoSize: CGSize

    var body: some View {
        GeometryReader { geo in
            let rect = ViewGeometry.videoRect(viewSize: geo.size, videoSize: videoSize)
            if let indicator = presence.indicators[deviceID], rect.width > 0 {
                ZStack(alignment: .topLeading) {
                    mark(indicator.kind, in: rect)
                    LabelCapsule(label: indicator.label)
                        .frame(width: rect.width, alignment: .center)
                        .offset(x: rect.minX, y: rect.minY + 12)
                }
                // 新提示替换旧提示时重建，动画从头开始
                .id(indicator.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: presence.indicators[deviceID]?.id)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func mark(_ kind: AIIndicator.Kind, in rect: CGRect) -> some View {
        switch kind {
        case .tap(let p): TapRipple(center: point(p, in: rect))
        case .longPress(let p, let seconds): HoldRing(center: point(p, in: rect), seconds: seconds)
        case .swipe(let a, let b): SwipeTrail(from: point(a, in: rect), to: point(b, in: rect))
        case .label: EmptyView()
        }
    }

    private func point(_ p: NormalizedPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + p.x * rect.width, y: rect.minY + p.y * rect.height)
    }
}

/// 点按：圆环从 12pt 扩到 48pt 并淡出，用时 0.6 秒。
private struct TapRipple: View {
    let center: CGPoint
    @State private var expanded = false

    var body: some View {
        let size: CGFloat = expanded ? 48 : 12
        Circle()
            .stroke(Theme.accent, lineWidth: 3)
            .frame(width: size, height: size)
            .opacity(expanded ? 0 : 1)
            .position(center)
            .onAppear { withAnimation(.easeOut(duration: 0.6)) { expanded = true } }
    }
}

/// 长按：圆环保持 `seconds` 秒（直到抬起）后淡出。
private struct HoldRing: View {
    let center: CGPoint
    let seconds: Double
    @State private var faded = false

    var body: some View {
        Circle()
            .stroke(Theme.accent, lineWidth: 3)
            .background(Circle().fill(Theme.accent.opacity(0.2)))
            .frame(width: 36, height: 36)
            .opacity(faded ? 0 : 1)
            .position(center)
            .task {
                try? await Task.sleep(for: .seconds(seconds))
                withAnimation(.easeOut(duration: 0.3)) { faded = true }
            }
    }
}

/// 滑动 / 滚动：起点到终点一条强调色轨迹，0.6 秒淡出。
private struct SwipeTrail: View {
    let from: CGPoint
    let to: CGPoint
    @State private var faded = false

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        .opacity(faded ? 0 : 1)
        .onAppear { withAnimation(.easeOut(duration: 0.6)) { faded = true } }
    }
}

/// 顶部提示胶囊：`AI: tap 登录`。
private struct LabelCapsule: View {
    let label: String

    var body: some View {
        Text("AI: \(label)")
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.onVideo)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.aiCapsule, in: Capsule())
    }
}
