import Testing
import CoreGraphics
import DeviceCore
@testable import Tandem

@MainActor
@Suite struct MirrorPaneTests {
    @Test func deviceMetaAndPopTitle() {
        #expect(WorkspaceText.deviceMeta(platform: .android, runningSize: CGSize(width: 1080, height: 2400), connection: .usb) == "Android · 1080×2400 · USB")
        #expect(WorkspaceText.deviceMeta(platform: .android, runningSize: nil, connection: .wifi) == "Android · Wi-Fi")
        #expect(WorkspaceText.popToggleTitle(popped: false) == "弹出为独立窗口" && WorkspaceText.popToggleTitle(popped: true) == "收回独立窗口")
    }

    @Test func statusTitleAndTone() {
        #expect(MirrorStatus.running.title == "实时" && MirrorStatus.running.tone == .success)
        #expect(MirrorStatus.failed.tone == .danger && MirrorStatus.connecting.tone == .neutral)
    }

    @Test func statusResolve() {
        #expect(MirrorStatus.resolve(isPresent: true, deviceState: .connected, popped: false, wanted: true, session: .running(width: 1, height: 2)) == .running)
        #expect(MirrorStatus.resolve(isPresent: false, deviceState: .connected, popped: false, wanted: true, session: .running(width: 1, height: 2)) == .offline)
        #expect(MirrorStatus.resolve(isPresent: true, deviceState: .connected, popped: true, wanted: true, session: .idle) == .popped)
    }

    @Test func stopTitle() {
        #expect(CaptureButtons.stopTitle(65) == "停止 01:05")
    }
}
