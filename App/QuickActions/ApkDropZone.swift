import AppKit
import SwiftUI

/// 应用卡片下方的虚线拖放区：拖入或点击选择 APK / 其他文件，经 `DropPlan.accepted` 过滤后交给 `onFiles`。
@MainActor
struct ApkDropZone: View {
    let canInstall: Bool
    let canPush: Bool
    let onFiles: ([URL]) -> Void

    @State private var hint: [String] = []

    private var hovering: Bool { !hint.isEmpty }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
        VStack(spacing: 4) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 18))
            Text("拖入 APK 安装 / 其他文件推送到 /sdcard/Download").font(.system(size: 12))
        }
        .foregroundStyle(Theme.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(hovering ? Theme.accent : Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
        .contentShape(shape)
        .onTapGesture(perform: choose)
        .onDrop(of: [.fileURL], delegate: FileDropDelegate(
            canInstall: canInstall, canPush: canPush, hint: $hint,
            onDrop: receive))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK else { return }
        deliver(panel.urls)
    }

    private func receive(_ providers: [NSItemProvider]) {
        Task { @MainActor in deliver(await DropPlan.urls(from: providers)) }
    }

    private func deliver(_ urls: [URL]) {
        let accepted = DropPlan.accepted(urls, canInstall: canInstall, canPush: canPush)
        if !accepted.isEmpty { onFiles(accepted) }
    }
}
