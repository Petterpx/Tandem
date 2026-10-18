import Testing
import AppKit
import DeviceCore
@testable import MagicDevX

@Test func cmdHIsHome() { #expect(KeyMapping.command(keyCode: 4, modifiers: .command) == .input(.key(.home))) }
@Test func escapeIsBack() { #expect(KeyMapping.command(keyCode: 53, modifiers: []) == .input(.key(.back))) }
@Test func cmdVIsPaste() { #expect(KeyMapping.command(keyCode: 9, modifiers: .command) == .pasteFromMac) }
@Test func plainLetterGoesToIME() { #expect(KeyMapping.command(keyCode: 0, modifiers: []) == nil) }
@Test func cmdShiftHIsNotHome() { #expect(KeyMapping.command(keyCode: 4, modifiers: [.command, .shift]) == nil) }
@Test func arrowsAndEditing() {
    #expect(KeyMapping.command(keyCode: 36, modifiers: []) == .input(.key(.enter)))
    #expect(KeyMapping.command(keyCode: 51, modifiers: []) == .input(.key(.delete)))
    #expect(KeyMapping.command(keyCode: 117, modifiers: []) == .input(.key(.forwardDelete)))
    #expect(KeyMapping.command(keyCode: 48, modifiers: []) == .input(.key(.tab)))
    #expect(KeyMapping.command(keyCode: 123, modifiers: []) == .input(.key(.left)))
    #expect(KeyMapping.command(keyCode: 124, modifiers: []) == .input(.key(.right)))
    #expect(KeyMapping.command(keyCode: 125, modifiers: []) == .input(.key(.down)))
    #expect(KeyMapping.command(keyCode: 126, modifiers: []) == .input(.key(.up)))
}
@Test func cmdShortcuts() {
    #expect(KeyMapping.command(keyCode: 1, modifiers: .command) == .input(.key(.recents)))
    #expect(KeyMapping.command(keyCode: 35, modifiers: .command) == .input(.key(.power)))
    #expect(KeyMapping.command(keyCode: 126, modifiers: .command) == .input(.key(.volumeUp)))
    #expect(KeyMapping.command(keyCode: 125, modifiers: .command) == .input(.key(.volumeDown)))
}
@Test func deviceIndependentFlagsOnly() {
    #expect(KeyMapping.command(keyCode: 4, modifiers: NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x1)) == .input(.key(.home)))
}
