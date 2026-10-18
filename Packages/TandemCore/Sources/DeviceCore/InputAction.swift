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

/// 触点来源：人（鼠标 / 触控板）与 AI 用不同的触点，同时操作时互不打断对方的手势。
public enum TouchPointer: Sendable {
    case finger, ai
}

public enum DeviceKey: String, Sendable {
    case back, home, recents, volumeUp, volumeDown, power, enter, delete, forwardDelete, tab, up, down, left, right
}

public enum InputAction: Equatable, Sendable {
    case touch(TouchPhase, NormalizedPoint, pointer: TouchPointer = .finger)
    case scroll(NormalizedPoint, dx: Double, dy: Double)
    case key(DeviceKey)
    case text(String)
}
