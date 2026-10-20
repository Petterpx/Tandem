import SwiftUI
import AndroidDriver

/// 「查看步骤」sheet：检测到的品牌排第一，后面补小米 / OPPO / vivo 三个常见品牌。
struct RomStepsSheet: View {
    let detected: RomGuide
    let onLater: () -> Void
    let onRecheck: () -> Void
    @Environment(\.dismiss) private var dismiss

    static func cards(for detected: RomGuide) -> [RomGuide] {
        let others = ["xiaomi", "oppo", "vivo"].map(RomGuide.forManufacturer).filter { $0.brand != detected.brand }
        return [detected] + others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开输入注入权限").font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.textPrimary)
            ForEach(Self.cards(for: detected), id: \.brand) { guide in
                VStack(alignment: .leading, spacing: 8) {
                    Text(guide.brand).font(.system(size: 13, weight: .semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                        }
                    }
                    .tandemText(.body)
                }
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tandemCard(padding: EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14))
            }
            Text("选项名称可能随系统版本变化，以手机上的实际选项为准。其他品牌请在开发者选项中查找与「USB 调试」「模拟点击」相关的开关。")
                .tandemText(.meta).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("稍后") { onLater(); dismiss() }
                    .buttonStyle(TandemButtonStyle(.secondary))
                Button("已打开，重新检测") { onRecheck(); dismiss() }
                    .buttonStyle(TandemButtonStyle(.primary))
            }
        }
        .padding(.vertical, 22)
        .padding(.horizontal, 24)
        .frame(width: 480)
        .background(Theme.windowBackground)
    }
}
