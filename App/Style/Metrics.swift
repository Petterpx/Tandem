import SwiftUI

/// 工作台尺寸常量：圆角、高度、分栏宽度与间距。
enum Metrics {
    // 圆角
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 8
    static let rowRadius: CGFloat = 9
    static let chipRadius: CGFloat = 8
    static let pillRadius: CGFloat = 12

    // 高度
    static let buttonHeight: CGFloat = 30
    static let cardRowMinHeight: CGFloat = 34
    static let deviceHeaderHeight: CGFloat = 48

    // 布局
    static let sidebarWidth: CGFloat = 232
    static let panelWidth: CGFloat = 372
    static let bottomHeight: CGFloat = 168
    static let mirrorMinWidth: CGFloat = 360

    // 间距
    static let sectionSpacing: CGFloat = 20
    static let headerToCard: CGFloat = 8

    // 开关
    static let switchSize = CGSize(width: 36, height: 20)
    static let knobSize: CGFloat = 16

    // 卡片内边距
    static let cardPadding = EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
}
