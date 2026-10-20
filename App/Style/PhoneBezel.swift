import SwiftUI

/// 手机外框几何：外圆角按宽度等比，内圆角 = 外圆角 - 框宽。
enum BezelGeometry {
    static let frame: CGFloat = 7

    static func outerRadius(width: CGFloat) -> CGFloat {
        width * 40 / 260
    }

    static func innerRadius(screenWidth: CGFloat) -> CGFloat {
        max(0, outerRadius(width: screenWidth + 2 * frame) - frame)
    }
}

/// 按自身宽度取内圆角的屏幕裁切形状。
struct BezelScreenShape: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: BezelGeometry.innerRadius(screenWidth: rect.width)).path(in: rect)
    }
}

/// 外框背景：圆角随外框 rect 宽度计算，避免 GeometryReader。
private struct BezelBackground: Shape {
    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: BezelGeometry.outerRadius(width: rect.width)).path(in: rect)
    }
}

extension View {
    /// 给镜像屏幕加 7 pt 黑色机身外框与投影。
    func phoneBezel() -> some View {
        padding(BezelGeometry.frame)
            .background(BezelBackground().fill(Theme.bezel))
            .shadow(color: Theme.shadowDeep.opacity(0.12), radius: 20, y: 20)
    }
}
