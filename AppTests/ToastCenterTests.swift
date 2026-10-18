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
}
