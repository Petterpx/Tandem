import DeviceCore
import Foundation
import Observation

/// 面板上显示的错误：按设备归属，附带可选的处理建议。
struct PanelError: Equatable {
    let deviceID: String
    let message: String
    let suggestion: String?
}

/// 所有面板操作的统一执行器：执行、写操作记录、把失败转成面板错误。
@MainActor @Observable
final class ActionRunner {
    private let log: ActivityLog
    private let now: () -> Date

    private(set) var lastError: PanelError?

    init(log: ActivityLog, now: @escaping () -> Date = Date.init) {
        self.log = log
        self.now = now
    }

    @discardableResult
    func perform<T>(
        _ title: String, device: DeviceInfo, source: ActivitySource = .user,
        _ body: () async throws -> T
    ) async -> T? {
        do {
            let value = try await body()
            record(title, device: device, source: source, failure: nil)
            if lastError?.deviceID == device.id { lastError = nil }
            return value
        } catch {
            let (message, suggestion) = Self.describe(error)
            record(title, device: device, source: source, failure: message)
            lastError = PanelError(deviceID: device.id, message: message, suggestion: suggestion)
            return nil
        }
    }

    /// 只写记录，不执行任何操作。
    func note(_ title: String, device: DeviceInfo, source: ActivitySource = .user, failure: String? = nil) {
        record(title, device: device, source: source, failure: failure)
    }

    func dismissError() { lastError = nil }

    private func record(_ title: String, device: DeviceInfo, source: ActivitySource, failure: String?) {
        log.append(ActivityEntry(id: UUID(), date: now(), source: source, deviceName: device.name, title: title, failure: failure))
    }

    private static func describe(_ error: Error) -> (String, String?) {
        if let e = error as? DeviceError { return (e.message, e.suggestion) }
        if let e = error as? LocalizedError, let d = e.errorDescription { return (d, e.recoverySuggestion) }
        return (String(describing: error), nil)
    }
}
