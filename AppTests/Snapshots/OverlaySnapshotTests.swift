import Foundation
import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct OverlaySnapshotTests {
    @Test func toastTransferDrop() throws {
        let shot = CaptureItem(
            id: UUID(), kind: .screenshot, url: URL(fileURLWithPath: "/tmp/Pixel 8 2026-10-19 10.00.00.png"),
            deviceName: "Pixel 8", date: Date(), duration: nil, fileSize: 120_000, thumbnailPNG: nil)
        let failed = TransferNotice(
            title: "推送 a.jpg 失败", detail: "空间不足", isError: true,
            revealPath: RevealTarget(deviceID: "HW1", path: "/sdcard/Download/a.jpg"))
        // 设计稿只有 600×420：提示条一列与 240×300 的拖放遮罩左右并排，进度条横跨在下方。
        let image = try SnapshotRenderer.render("overlay-toast-transfer-drop", size: CGSize(width: 600, height: 420)) {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 12) {
                        ToastCardView(content: .capture(shot, note: "1080×2400 · 投屏画质 · 已复制到剪贴板"))
                        ToastCardView(content: .transfer(failed))
                    }
                    ZStack {
                        Theme.videoBackground
                        DropOverlay(lines: ["松开以安装", "松开以推送到 Download"], rounded: true)
                    }
                    .frame(width: 240, height: 300)
                    .clipShape(BezelScreenShape())
                }
                TransferStrip(label: "推送 a.jpg · 还有 2 项", fraction: 0.45, percent: "45%") {}
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Theme.canvas)
        }
        #expect(image.width == 1200 && image.height == 840)
    }
}
