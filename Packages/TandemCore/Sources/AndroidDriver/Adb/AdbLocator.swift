import Foundation
import DeviceCore

public struct Adb: Sendable, Equatable {
    public var url: URL
    public var version: String

    public init(url: URL, version: String) {
        self.url = url
        self.version = version
    }
}

public struct AdbLocator: Sendable {
    private let runner: any ProcessRunner
    private let environment: [String: String]
    private let home: URL
    private let bundled: URL?
    private let fileExists: @Sendable (String) -> Bool

    public init(
        runner: any ProcessRunner,
        environment: [String: String],
        home: URL,
        bundled: URL?,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.runner = runner
        self.environment = environment
        self.home = home
        self.bundled = bundled
        self.fileExists = fileExists
    }

    /// 候选顺序：用户 PATH、ANDROID_HOME、ANDROID_SDK_ROOT、~/Library/Android/sdk、homebrew、/usr/local、内置。
    public func candidates() async -> [URL] {
        var paths: [String] = []
        if let result = try? await runner.run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v adb"], timeout: .seconds(5)),
           result.exitCode == 0,
           let line = result.stdoutString.split(whereSeparator: \.isNewline).last {
            let path = line.trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("/") { paths.append(path) }
        }
        if let h = environment["ANDROID_HOME"], !h.isEmpty { paths.append(h + "/platform-tools/adb") }
        if let h = environment["ANDROID_SDK_ROOT"], !h.isEmpty { paths.append(h + "/platform-tools/adb") }
        paths.append(home.path + "/Library/Android/sdk/platform-tools/adb")
        paths.append("/opt/homebrew/bin/adb")
        paths.append("/usr/local/bin/adb")
        if let bundled { paths.append(bundled.path) }

        var seen = Set<String>()
        return paths
            .filter { seen.insert($0).inserted && fileExists($0) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func locate() async throws -> Adb {
        for url in await candidates() {
            guard let result = try? await runner.run(url, ["version"], timeout: .seconds(3)),
                  result.exitCode == 0 else { continue }
            let out = result.stdoutString
            guard out.contains("Android Debug Bridge"),
                  let match = out.firstMatch(of: /Version (\S+)/) else { continue }
            return Adb(url: url, version: String(match.1))
        }
        throw DeviceError.adbNotFound()
    }
}
