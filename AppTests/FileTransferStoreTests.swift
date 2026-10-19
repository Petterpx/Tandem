import Foundation
import Testing
@testable import Tandem

@MainActor
struct FileTransferStoreTests {
    private func make(_ defaults: UserDefaults = UserDefaults(suiteName: UUID().uuidString)!) -> FileTransferStore {
        FileTransferStore(defaults: defaults, home: URL(fileURLWithPath: "/Users/x"))
    }

    @Test func storeDefaultsAndRecents() {
        let store = make()
        #expect(store.pullDirectory.path == "/Users/x/Downloads")
        #expect(store.rememberedPaste == nil)
        for i in 1...6 { store.recordDirectory("/sdcard/d\(i)") }
        store.recordDirectory("/sdcard/d4")
        #expect(store.recentDirectories == ["/sdcard/d4", "/sdcard/d6", "/sdcard/d5", "/sdcard/d3", "/sdcard/d2"])
    }

    @Test func persistsAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = make(defaults)
        let choice = PasteChoice(dest: "/sdcard/DCIM", installAPK: true, mediaScan: true, conflict: .overwrite, heicToJPEG: false)
        store.pullDirectory = URL(fileURLWithPath: "/tmp/pulls")
        store.rememberedPaste = choice
        store.recordDirectory("/sdcard/a")
        let again = make(defaults)
        #expect(again.pullDirectory.path == "/tmp/pulls")
        #expect(again.rememberedPaste == choice)
        #expect(again.recentDirectories == ["/sdcard/a"])
        again.rememberedPaste = nil
        #expect(make(defaults).rememberedPaste == nil)
    }

    @Test func recentDirectoriesIgnoreTrailingSlash() {
        let store = FileTransferStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.recordDirectory("/sdcard/Download/")
        store.recordDirectory("/sdcard/Download")
        store.recordDirectory("/")
        #expect(store.recentDirectories == ["/", "/sdcard/Download"])
    }
}
