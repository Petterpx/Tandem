import SwiftUI
import AndroidDriver

/// 「无法注入点击」单行横幅：查看步骤（弹 sheet）与关闭；步骤本身在 RomStepsSheet。
struct RomBannerView: View {
    let guide: RomGuide
    let onReconnect: () -> Void
    let onDismiss: () -> Void

    @State private var showSteps = false
    @State private var closeHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 16))
            Text("无法注入点击：需要额外开启调试权限")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("查看步骤") { showSteps = true }
                .buttonStyle(TandemButtonStyle(.link, tint: Theme.warnText))
                .fontWeight(.semibold)
            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.warnText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Theme.warnText.opacity(closeHovered ? 0.16 : 0.08)))
                .contentShape(Circle())
                .onHover { closeHovered = $0 }
                .onTapGesture(perform: onDismiss)
                .accessibilityLabel("关闭提示")
                .accessibilityAddTraits(.isButton)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.warnText)
        .padding(.vertical, 9)
        .padding(.horizontal, 12)
        .background(shape.fill(Theme.warnTint))
        .overlay(shape.strokeBorder(Theme.warnBorder, lineWidth: 1))
        .shadow(color: Theme.shadow.opacity(0.04), radius: 1, y: 1)
        .padding(.horizontal, 16)
        .sheet(isPresented: $showSteps) {
            RomStepsSheet(detected: guide, onLater: {}, onRecheck: onReconnect)
        }
    }
}
