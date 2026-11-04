import DeviceCore
import Foundation

enum SimulatorInput {
    static func point(_ point: NormalizedPoint) throws -> NormalizedPoint {
        guard point.x.isFinite, point.y.isFinite else { throw DeviceError(code: .INVALID_ARGUMENT, message: "触控坐标必须是有限数值") }
        return .init(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    static func scrollPoints(at point: NormalizedPoint, dx: Double, dy: Double) throws -> [NormalizedPoint] {
        let start = try self.point(point)
        guard dx.isFinite, dy.isFinite else { throw DeviceError(code: .INVALID_ARGUMENT, message: "滚动量必须是有限数值") }
        // Android hscroll positive moves content left; vscroll positive moves content down.
        let end = try self.point(.init(x: start.x - min(0.25, max(-0.25, dx * 0.025)),
                                       y: start.y + min(0.25, max(-0.25, dy * 0.025))))
        return (0...5).map { index in
            let fraction = Double(index) / 5
            return .init(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
        }
    }

    static func touch(_ phase: String, at point: NormalizedPoint, pointer: TouchPointer) throws -> SimulatorRequest {
        let point = try self.point(point)
        return SimulatorRequest(command: "touch", phase: phase, x: point.x, y: point.y, pointer: pointer == .ai ? "ai" : "finger")
    }
}
