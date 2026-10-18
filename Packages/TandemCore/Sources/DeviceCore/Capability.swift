public enum Capability: String, Sendable, CaseIterable {
    case mirror, touch, keys, text, clipboard, screenshot, record, uiTree
    case network, apps, openURL, devOptions, systemSettings, shell
}
