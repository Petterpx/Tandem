import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ToastCenterTests {
    private func item() -> CaptureItem {
        CaptureItem(id: UUID(), kind: .screenshot, url: URL(fileURLWithPath: "/tmp/a.png"), deviceName: "d",
                    date: Date(), duration: nil, fileSize: 1, thumbnailPNG: nil)
    }

    @Test func newerToastReplacesOlderAndStaleDismissIsIgnored() {
        let center = ToastCenter()
        center.show(item(), note: nil, in: .workspace)
        let a = center.current[.workspace]!
        center.show(item(), note: "n", in: .workspace)
        let b = center.current[.workspace]!
        center.dismiss(a.id, in: .workspace)
        #expect(center.current[.workspace] == b)
        center.dismiss(b.id, in: .workspace)
        #expect(center.current[.workspace] == nil)
    }

    @Test func originsAreIndependent() {
        let center = ToastCenter()
        center.show(item(), note: nil, in: .workspace)
        center.show(item(), note: nil, in: .popup("HW1"))
        #expect(center.current.count == 2)
    }

    @Test func countdownPausesWhileHovering() {
        let t0 = ContinuousClock.now
        var c = ToastCountdown()
        c.resume(at: t0)
        c.pause(at: t0 + .seconds(1))
        #expect(c.remaining(at: t0 + .seconds(10)) == .milliseconds(1000))
        c.pause(at: t0 + .seconds(11))                       // 重复暂停无影响
        c.resume(at: t0 + .seconds(12))
        #expect(c.remaining(at: t0 + .milliseconds(12500)) == .milliseconds(500))
        #expect(c.remaining(at: t0 + .seconds(60)) == .zero)
    }

    @Test func countdownIsTwoSecondsAndRepeatedResumeKeepsStart() {
        let t0 = ContinuousClock.now
        var c = ToastCountdown()
        #expect(ToastCountdown.total == .seconds(2))
        #expect(c.remaining(at: t0 + .seconds(5)) == .seconds(2))  // 未开始不计时
        c.resume(at: t0)
        c.resume(at: t0 + .seconds(1))                       // 重复继续不重置起点
        #expect(c.remaining(at: t0 + .milliseconds(1500)) == .milliseconds(500))
    }

    /// 点「在 Finder 中显示」后 Finder 到前台，onHover(false) 不会触发：失去激活 / 失去 key 要当作移开。
    @Test func resigningActiveOrKeyResumesPausedCountdown() {
        let t0 = ContinuousClock.now
        for leave in [ToastPointerEvent.appResignedActive, .windowResignedKey, .exited] {
            var timer = ToastTimer()
            timer.start(at: t0)
            timer.handle(.entered, at: t0 + .milliseconds(500))
            #expect(timer.hovering)
            #expect(timer.countdown.remaining(at: t0 + .seconds(30)) == .milliseconds(1500))
            timer.handle(leave, at: t0 + .seconds(30))
            #expect(!timer.hovering)
            #expect(timer.countdown.remaining(at: t0 + .seconds(31)) == .milliseconds(500))
            #expect(timer.countdown.remaining(at: t0 + .seconds(32)) == .zero)
        }
    }

    @Test func startWhileHoveringStaysPaused() {
        let t0 = ContinuousClock.now
        var timer = ToastTimer()
        timer.handle(.entered, at: t0)
        timer.start(at: t0)
        #expect(timer.countdown.remaining(at: t0 + .seconds(10)) == .seconds(2))
    }

    @Test func actionRunsThenDismissesImmediately() {
        let center = ToastCenter()
        center.show(item(), note: nil, in: .workspace)
        let toast = center.current[.workspace]!
        var ran = false
        center.performAndDismiss(toast.id, in: .workspace) {
            // 动作执行时提示条还在（先执行后收起）
            ran = center.current[.workspace] == toast
        }
        #expect(ran)
        #expect(center.current[.workspace] == nil)
    }

    @Test func staleActionDoesNotDismissNewerToast() {
        let center = ToastCenter()
        center.show(item(), note: nil, in: .workspace)
        let old = center.current[.workspace]!
        center.show(item(), note: "n", in: .workspace)
        let newer = center.current[.workspace]!
        center.performAndDismiss(old.id, in: .workspace) {}
        #expect(center.current[.workspace] == newer)
    }

    @Test func toastText() {
        let shot = CaptureItem(id: UUID(), kind: .screenshot, url: URL(fileURLWithPath: "/tmp/Pixel 8 截图.png"),
                               deviceName: "d", date: Date(), duration: nil, fileSize: 1, thumbnailPNG: nil)
        let recording65s = CaptureItem(id: UUID(), kind: .recording, url: URL(fileURLWithPath: "/tmp/r.mp4"),
                                       deviceName: "d", date: Date(), duration: 65, fileSize: 2_000_000, thumbnailPNG: nil)
        #expect(ToastText.title(.capture(shot, note: "64×48 · 投屏画质 · 已复制到剪贴板")) == "截图已保存")
        #expect(ToastText.subtitle(.capture(shot, note: "64×48 · 投屏画质 · 已复制到剪贴板")) == "64×48 · 投屏画质 · 已复制到剪贴板")
        #expect(ToastText.subtitle(.capture(shot, note: nil)) == "Pixel 8 截图.png")
        #expect(ToastText.title(.capture(recording65s, note: nil)) == "录屏已保存")
        #expect(ToastText.subtitle(.capture(recording65s, note: nil))?.hasPrefix("01:05 · ") == true)
        #expect(ToastText.title(.capture(recording65s, note: "设备已断开，已保存已录制部分")) == "设备已断开，已保存已录制部分")
        #expect(ToastText.isError(.capture(shot, note: nil)) == false)

        let failed = TransferNotice(title: "推送 a.jpg 失败", detail: "空间不足", isError: true, revealPath: nil)
        #expect(ToastText.title(.transfer(failed)) == "推送 a.jpg 失败")
        #expect(ToastText.subtitle(.transfer(failed)) == "空间不足")
        #expect(ToastText.isError(.transfer(failed)))
        let ok = TransferNotice(title: "已安装 com.x.app", detail: nil, isError: false, revealPath: nil)
        #expect(ToastText.subtitle(.transfer(ok)) == nil)
        #expect(ToastText.isError(.transfer(ok)) == false)
    }
}
