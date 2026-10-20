import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct TransferNoticeTests {
    private func job(_ kind: TransferKind, _ state: TransferJob.State, note: String? = nil) -> TransferJob {
        TransferJob(id: UUID(), deviceID: "HW1", kind: kind, origin: .workspace, source: .user, state: state, note: note)
    }

    private func push(_ names: [String]) -> TransferKind {
        .push(locals: names.map { URL(fileURLWithPath: "/tmp/\($0)") }, dest: "/sdcard/Download/", conflict: .rename, mediaScan: false)
    }

    @Test func singlePush() {
        let n = TransferNotice.from(job(push(["a.jpg"]), .done(.pushed(["/sdcard/Download/a.jpg"]))))
        #expect(n?.title == "已推送到 /sdcard/Download/a.jpg")
        #expect(n?.isError == false)
        #expect(n?.detail == nil)
        #expect(n?.revealPath == RevealTarget(deviceID: "HW1", path: "/sdcard/Download/a.jpg"))
    }

    @Test func multiPushNamesDirectory() {
        let paths = ["/sdcard/Download/a.jpg", "/sdcard/Download/b.jpg", "/sdcard/Download/c.jpg"]
        let n = TransferNotice.from(job(push(["a.jpg", "b.jpg", "c.jpg"]), .done(.pushed(paths))))
        #expect(n?.title == "已推送 3 个文件到 /sdcard/Download")
        #expect(n?.revealPath == RevealTarget(deviceID: "HW1", path: "/sdcard/Download/a.jpg"))
    }

    @Test func mediaScanFailureNoteBecomesDetail() {
        let n = TransferNotice.from(job(push(["a.jpg"]), .done(.pushed(["/sdcard/Download/a.jpg"])), note: "未能加入相册"))
        #expect(n?.detail == "未能加入相册")
        #expect(n?.isError == false)
    }

    @Test func install() {
        let kind = TransferKind.install(apk: URL(fileURLWithPath: "/tmp/app.apk"))
        #expect(TransferNotice.from(job(kind, .done(.installed("com.x.app"))))?.title == "已安装 com.x.app")
        let unknown = TransferNotice.from(job(kind, .done(.installed(nil))))
        #expect(unknown?.title == "安装成功")
        #expect(unknown?.revealPath == nil)
    }

    @Test func pull() {
        let kind = TransferKind.pull(remote: "/sdcard/x.log", to: URL(fileURLWithPath: "/tmp"))
        let n = TransferNotice.from(job(kind, .done(.pulled(URL(fileURLWithPath: "/tmp/x.log")))))
        #expect(n?.title == "已拉取到 /tmp/x.log")
        #expect(n?.revealPath == nil)
    }

    @Test func failedIsRedWithMessage() {
        let e = DeviceError(code: .CONNECTION_FAILED, message: "空间不足")
        let n = TransferNotice.from(job(push(["a.jpg"]), .failed(e)))
        #expect(n?.title == "推送 a.jpg 失败")
        #expect(n?.detail == "空间不足")
        #expect(n?.isError == true)
    }

    @Test func cancelledAndUnfinishedHaveNoNotice() {
        #expect(TransferNotice.from(job(push(["a.jpg"]), .cancelled)) == nil)
        #expect(TransferNotice.from(job(push(["a.jpg"]), .waiting)) == nil)
    }

    @Test func toastCenterShowsTransferNotice() {
        let center = ToastCenter()
        let n = TransferNotice(title: "t", detail: nil, isError: false, revealPath: nil)
        center.show(n, in: .popup("HW1"))
        #expect(center.current[.popup("HW1")]?.content == .transfer(n))
    }
}

@MainActor
@Suite struct TransferDropAndBarTests {
    private func urls(_ names: [String]) -> [URL] { names.map { URL(fileURLWithPath: "/tmp/\($0)") } }

    @Test func dropFiltersByCapabilityKeepingOrder() {
        let all = urls(["a.jpg", "b.apk", "c.txt"])
        #expect(DropPlan.accepted(all, canInstall: true, canPush: true) == all)
        #expect(DropPlan.accepted(all, canInstall: false, canPush: true) == urls(["a.jpg", "c.txt"]))
        #expect(DropPlan.accepted(all, canInstall: true, canPush: false) == urls(["b.apk"]))
        #expect(DropPlan.accepted(urls(["a.jpg"]), canInstall: true, canPush: false).isEmpty)
    }

    @Test func dropHint() {
        let both = ["松开以安装", "松开以推送到 Download"]
        #expect(DropPlan.hint(forNames: ["a.jpg"], canInstall: true, canPush: true) == ["松开以推送到 Download"])
        #expect(DropPlan.hint(forNames: ["a.apk"], canInstall: true, canPush: true) == ["松开以安装"])
        #expect(DropPlan.hint(forNames: ["a.apk", "b.jpg"], canInstall: true, canPush: true) == both)
        #expect(DropPlan.hint(forNames: ["a.apk", "b.jpg"], canInstall: false, canPush: true) == ["松开以推送到 Download"])
        #expect(DropPlan.hint(forNames: ["a.apk", "b.jpg"], canInstall: true, canPush: false) == ["松开以安装"])
        #expect(DropPlan.hint(forNames: ["a.jpg"], canInstall: true, canPush: false).isEmpty)
        #expect(DropPlan.hint(forNames: ["a.apk"], canInstall: false, canPush: true).isEmpty)
    }

    private func job(_ kind: TransferKind, _ state: TransferJob.State) -> TransferJob {
        TransferJob(id: UUID(), deviceID: "HW1", kind: kind, origin: .workspace, source: .user, state: state)
    }

    @Test func progressLabels() {
        let push = TransferKind.push(locals: [URL(fileURLWithPath: "/tmp/a.jpg")], dest: "/sdcard/Download/", conflict: .rename, mediaScan: false)
        let running45 = job(push, .running(TransferProgress(bytes: 45, total: 100), phase: "推送"))
        #expect(TransferProgressBar.label(running45, remaining: 2) == "推送 a.jpg · 还有 2 项")
        #expect(TransferProgressBar.percentText(running45) == "45%")
        let apk = TransferKind.install(apk: URL(fileURLWithPath: "/tmp/app.apk"))
        let apkPushing80 = job(apk, .running(TransferProgress(bytes: 80, total: 100), phase: "推送"))
        #expect(TransferProgressBar.label(apkPushing80, remaining: 0) == "安装 app.apk · 推送中")
        #expect(TransferProgressBar.percentText(apkPushing80) == "80%")
        let installing = job(apk, .running(TransferProgress(bytes: 100, total: 100), phase: "安装中"))
        #expect(TransferProgressBar.label(installing, remaining: 0) == "安装 app.apk · 安装中…")
        #expect(TransferProgressBar.percentText(installing) == "")
        #expect(TransferProgressBar.label(job(push, .waiting), remaining: 0) == "推送 a.jpg")
        #expect(TransferProgressBar.percentText(job(push, .waiting)) == "")
    }

    @Test func urlsFromProvidersKeepOrder() async {
        let urls = [URL(fileURLWithPath: "/tmp/a.apk"), URL(fileURLWithPath: "/tmp/b.jpg")]
        #expect(await DropPlan.urls(from: urls.map { NSItemProvider(object: $0 as NSURL) }) == urls)
    }
}
