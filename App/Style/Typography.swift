import SwiftUI

/// 工作台字号体系：角色决定字号、字重、字距与是否等宽，视图不直接写数字。
enum TextRole {
    case headerTitle, sectionTitle, body, button, meta, chip, mono, monoMeta

    var size: CGFloat {
        switch self {
        case .headerTitle: 14
        case .sectionTitle: 11
        case .body: 13
        case .button, .mono: 12
        case .meta, .monoMeta: 11
        case .chip: 10
        }
    }

    var weight: Font.Weight {
        switch self {
        case .headerTitle: .bold
        case .sectionTitle: .semibold
        default: .regular
        }
    }

    /// 字距（pt）；只有分区标题带字距。
    var tracking: CGFloat {
        self == .sectionTitle ? 0.44 : 0
    }

    var monospaced: Bool {
        self == .mono || self == .monoMeta
    }
}

extension Font {
    static func tandem(_ role: TextRole) -> Font {
        .system(size: role.size, weight: role.weight, design: role.monospaced ? .monospaced : .default)
    }
}

extension View {
    /// 套用角色的字体与字距。
    func tandemText(_ role: TextRole) -> some View {
        font(.tandem(role)).tracking(role.tracking)
    }
}
