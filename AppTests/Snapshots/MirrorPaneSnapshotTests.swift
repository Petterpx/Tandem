import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct MirrorPaneSnapshotTests {
    @Test func headerCanvasBezelToolbar() throws {
        let image = try SnapshotRenderer.render("mirror-pane-header-canvas", size: CGSize(width: 720, height: 760)) {
            VStack(spacing: 0) {
                MirrorHeaderBar(name: "Pixel 8", meta: "Android · 1080×2400 · USB", status: .running, popped: false) {}
                ZStack {
                    Theme.canvas
                    DotGrid()
                    VStack(spacing: 12) {
                        // 代替 VideoSurface（ImageRenderer 不渲染 AppKit 视图）
                        Theme.videoBackground
                            .aspectRatio(1080.0 / 2400, contentMode: .fit)
                            .frame(height: 520)
                            .clipShape(BezelScreenShape())
                            .phoneBezel()
                        ToolbarPill {
                            ForEach(["chevron.backward", "circle", "square.on.square"], id: \.self) { symbol in
                                Button {} label: { Image(systemName: symbol) }
                                    .buttonStyle(TandemButtonStyle(.icon))
                            }
                            Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 4)
                            CaptureButtonsContent(
                                style: .toolbar, canShot: true, shotBusy: false, recordingStartedAt: nil,
                                canRecord: true, isRunning: true, onShot: {}, onRecord: {})
                            CaptureButtonsContent(
                                style: .toolbar, canShot: true, shotBusy: false,
                                recordingStartedAt: Date().addingTimeInterval(-65),
                                canRecord: true, isRunning: true, onShot: {}, onRecord: {})
                        }
                    }
                }
            }
        }
        #expect(image.width == 1440 && image.height == 1520)
    }
}
