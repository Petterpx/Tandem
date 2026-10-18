/// 归一化坐标：0...1，原点左上。
public struct NormalizedPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public enum TouchPhase: Sendable {
    case down, move, up
}

public enum DeviceKey: String, Sendable {
    case back, home, recents, volumeUp, volumeDown, power, enter, delete, forwardDelete, tab, up, down, left, right
}

public enum InputAction: Equatable, Sendable {
    case touch(TouchPhase, NormalizedPoint)
    case scroll(NormalizedPoint, dx: Double, dy: Double)
    case key(DeviceKey)
    case text(String)
}
