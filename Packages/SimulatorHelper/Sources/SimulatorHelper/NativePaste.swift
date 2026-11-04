import Foundation
import CoreGraphics
import FBSimulatorAX
import FBSimulatorControl

// Read only the system edit menu. This is not an exported UI-automation capability.
struct MenuNode {
    var label: String
    var identifier: String?
    var role: String
    var frame: CGRect
    var enabled: Bool
    var keyboardKey: Bool
    var children: [MenuNode]

    init(_ element: AccessibilityDocumentElement) {
        label = element.label.flatMap { $0 } ?? ""
        identifier = element.identifier.flatMap { $0 }
        role = element.type.flatMap { $0 } ?? ""
        let frame = element.frame.flatMap { $0 }
        self.frame = CGRect(x: frame?.x ?? 0, y: frame?.y ?? 0, width: frame?.width ?? 0, height: frame?.height ?? 0)
        enabled = element.enabled.flatMap { $0 } ?? true
        keyboardKey = (element.traits.flatMap { $0 } ?? []).contains("KeyboardKey")
        children = (element.children ?? []).map(MenuNode.init)
    }

    private static let editingLabels = PasteMenu.labels.union([
        "Cut", "Copy", "Select", "Select All", "AutoFill", "Look Up", "Translate", "Share", "Share…", "Writing Tools", "B/I/U",
        "剪切", "剪下", "拷贝", "拷貝", "复制", "複製", "选择", "選取", "全选", "全選", "自动填充", "自動填寫", "自動填入", "查询", "查詢", "翻译", "翻譯", "共享", "分享", "写作工具", "書寫工具",
        "カット", "コピー", "選択", "すべて選択", "すべてを選択", "自動入力", "調べる", "翻訳", "共有", "作文ツール",
        "Couper", "Copier", "Tout sélectionner", "Ausschneiden", "Kopieren", "Alles auswählen", "Cortar", "Copiar", "Seleccionar todo",
    ])

    private var nativeContainer: Bool {
        if role == "Menu" || role == "MenuItem" { return true }
        // Older UIKit menus expose an anonymous group, rather than the Menu role.
        // Unlike an app button or keyboard suggestion, all its children are anonymous
        // editing actions and none is a keyboard key.
        return role == "Group" && label.isEmpty && (identifier ?? "").isEmpty && children.count >= 2 &&
            children.allSatisfy { ["Button", "MenuItem", "StaticText"].contains($0.role) && ($0.identifier ?? "").isEmpty && !$0.keyboardKey && Self.editingLabels.contains($0.label) } &&
            children.contains { PasteMenu.labels.contains($0.label) }
    }

    func items(inMenu: Bool = false) -> [MenuItem] {
        let native = inMenu || nativeContainer
        var result: [MenuItem] = []
        if enabled, ["Button", "MenuItem", "StaticText"].contains(role), !keyboardKey, frame.width > 0, frame.height > 0 {
            result.append(MenuItem(label: label, identifier: identifier, role: role, frame: frame, isNativeMenu: native))
        }
        return result + children.flatMap { $0.items(inMenu: native) }
    }
}

@MainActor
func readMenu(_ simulator: Simulator) async throws -> [MenuItem] {
    let ui = try simulator.uiAutomation(backend: .accessibility)
    let options = AccessibilityRequestOptions(
        format: .nested, keys: [.label, .uniqueID, .type, .frameDict, .enabled, .traits],
        timing: .init(elementTimeout: 1, queryTimeout: 2))
    let response = try await ui.describe(.frontmost, options: options)
    return response.elements.elements.map(MenuNode.init).flatMap { $0.items() }
}
