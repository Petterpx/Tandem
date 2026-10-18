import AppKit
import Testing
@testable import Tandem

@MainActor
@Suite struct VideoSurfaceViewTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        return window
    }

    @Test func workspaceSurfaceDoesNotTakeFocusOnAppear() {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.sizesWindow = false
        window.contentView?.addSubview(surface)
        #expect(window.firstResponder !== surface)
    }

    @Test func popupSurfaceTakesFocusOnAppear() {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.sizesWindow = true
        window.contentView?.addSubview(surface)
        #expect(window.firstResponder === surface)
    }
}
