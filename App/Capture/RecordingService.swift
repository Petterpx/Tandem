import DeviceCore
import Foundation
import MediaKit
import Observation

struct ActiveRecording: Equatable {
    let startedAt: Date
    let origin: ToastOrigin
    let deviceName: String
}

/// 每台设备至多一路录屏。录屏自己订阅会话的帧，不依赖投屏视图，
/// 所以关掉视图或切换设备都不会中断录制。
@MainActor @Observable
final class RecordingService {
    private struct Entry {
        let recorder: CanvasRecorder
        let session: any DeviceSession
        let token: FrameObserverToken
        let url: URL
    }

    private let store: CaptureStore
    private let now: () -> Date
    private let makeRecorder: (URL) -> CanvasRecorder

    private(set) var active: [String: ActiveRecording] = [:]
    @ObservationIgnored private var entries: [String: Entry] = [:]

    init(
        store: CaptureStore, now: @escaping () -> Date = Date.init,
        makeRecorder: @escaping (URL) -> CanvasRecorder = { CanvasRecorder(url: $0) }
    ) {
        self.store = store
        self.now = now
        self.makeRecorder = makeRecorder
    }

    func isRecording(_ id: String) -> Bool { active[id] != nil }

    func start(_ id: String, deviceName: String, session: any DeviceSession, origin: ToastOrigin) throws {
        guard active[id] == nil else {
            throw DeviceError(code: .UNSUPPORTED, message: "该设备正在录屏")
        }
        // 排除进行中的路径，避免同名设备同一秒开录时写到同一文件。
        let url = try store.nextRecordingURL(deviceName: deviceName, excluding: Set(entries.values.map(\.url)))
        let recorder = makeRecorder(url)
        let token = session.addFrameObserver { recorder.append($0) }
        entries[id] = Entry(recorder: recorder, session: session, token: token, url: url)
        active[id] = ActiveRecording(startedAt: now(), origin: origin, deviceName: deviceName)
    }

    func stop(_ id: String) async throws -> CaptureItem {
        // 同步摘除并退订（先于任何 await），并发的第二次 stop 会直接抛"未在录屏"。
        guard let (entry, info) = detach(id) else {
            throw DeviceError(code: .UNSUPPORTED, message: "该设备未在录屏")
        }
        return try await finish(entry, deviceName: info.deviceName)
    }

    /// 同步清空后并发收尾所有录屏（退出 App 时有时间预算）。
    func stopAll() async -> [String: Result<CaptureItem, any Error>] {
        let detached = active.keys.compactMap { id in detach(id).map { (id, $0.0, $0.1) } }
        var results: [String: Result<CaptureItem, any Error>] = [:]
        await withTaskGroup(of: (String, Result<RecordingSummary, any Error>).self) { group in
            for (id, entry, _) in detached {
                group.addTask {
                    do { return (id, .success(try await entry.recorder.finish())) } catch { return (id, .failure(error)) }
                }
            }
            for await (id, result) in group {
                let name = detached.first { $0.0 == id }?.2.deviceName ?? ""
                results[id] = result.map { store.addRecording($0, deviceName: name) }
            }
        }
        return results
    }

    private func detach(_ id: String) -> (Entry, ActiveRecording)? {
        guard let entry = entries.removeValue(forKey: id), let info = active.removeValue(forKey: id) else { return nil }
        entry.session.removeFrameObserver(entry.token)
        return (entry, info)
    }

    private func finish(_ entry: Entry, deviceName: String) async throws -> CaptureItem {
        let summary = try await entry.recorder.finish()
        return store.addRecording(summary, deviceName: deviceName)
    }
}
