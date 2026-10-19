/// logcat 日志级别，按严重程度排序。
public enum LogLevel: String, CaseIterable, Comparable, Sendable {
    case verbose = "V", debug = "D", info = "I", warn = "W", error = "E", fatal = "F"

    private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

/// 一条 logcat 记录。
public struct LogEntry: Equatable, Sendable {
    public var time: String
    public var pid: Int
    public var tid: Int
    public var level: LogLevel
    public var tag: String
    public var message: String

    public init(time: String, pid: Int, tid: Int, level: LogLevel, tag: String, message: String) {
        self.time = time
        self.pid = pid
        self.tid = tid
        self.level = level
        self.tag = tag
        self.message = message
    }
}

/// 日志快照查询条件。
public struct LogQuery: Equatable, Sendable {
    public var package: String?
    public var minLevel: LogLevel
    public var grep: String?
    public var lines: Int

    public init(package: String? = nil, minLevel: LogLevel = .verbose, grep: String? = nil, lines: Int = 200) {
        self.package = package
        self.minLevel = minLevel
        self.grep = grep
        self.lines = lines
    }
}

/// 日志快照：记录、命中的 pid 与附注。
public struct LogSnapshot: Equatable, Sendable {
    public var entries: [LogEntry]
    public var pids: [Int]
    public var note: String?

    public init(entries: [LogEntry], pids: [Int], note: String? = nil) {
        self.entries = entries
        self.pids = pids
        self.note = note
    }
}
