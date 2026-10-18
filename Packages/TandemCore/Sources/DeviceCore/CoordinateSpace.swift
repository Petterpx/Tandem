import Foundation

/// AI 使用的坐标空间：长边固定 1280，短边按屏幕比例缩放。
public struct CoordinateSpace: Equatable, Sendable {
    public static let longEdge = 1280

    public let width: Int
    public let height: Int

    public init?(screenWidth: Double, screenHeight: Double) {
        guard screenWidth > 0, screenHeight > 0 else { return nil }
        let long = Double(Self.longEdge)
        if screenWidth >= screenHeight {
            width = Self.longEdge
            height = Int((long * screenHeight / screenWidth).rounded())
        } else {
            height = Self.longEdge
            width = Int((long * screenWidth / screenHeight).rounded())
        }
    }

    /// 空间坐标 → 归一化坐标，夹到 0…1。
    public func normalized(x: Double, y: Double) -> NormalizedPoint {
        NormalizedPoint(
            x: min(max(x / Double(width), 0), 1),
            y: min(max(y / Double(height), 0), 1)
        )
    }

    /// 归一化坐标 → 空间坐标（四舍五入）。
    public func point(_ p: NormalizedPoint) -> (x: Int, y: Int) {
        (Int((p.x * Double(width)).rounded()), Int((p.y * Double(height)).rounded()))
    }
}
