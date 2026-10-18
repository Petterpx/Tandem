import Foundation

public enum ControlPaths {
    /// 控制 socket 路径：`<home>/Library/Application Support/Tandem/control.sock`。
    public static func socketURL(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Tandem/control.sock")
    }
}
