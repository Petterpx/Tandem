import Foundation
import Darwin

/// Serializes cooperating helpers even when CoreDevice shares a host pasteboard.
/// The descriptor is close-on-exec, so a clipboard subprocess cannot prolong the lease.
final class ClipboardLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(descriptor: Int32) { self.descriptor = descriptor }

    static func acquire(path: String = "/tmp/tandem-simulator-\(getuid()).clipboard.lock", timeout: Duration = .seconds(8)) async throws -> ClipboardLease {
        let descriptor = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Could not open the shared clipboard lock") }
        var transferred = false
        defer { if !transferred { Darwin.close(descriptor) } }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(), metadata.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Clipboard lock is not a private regular file owned by this user")
        }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                transferred = true
                return ClipboardLease(descriptor: descriptor)
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                throw HelperFailure(code: "CONNECTION_FAILED", message: "Could not acquire the shared clipboard lock")
            }
            guard .now < deadline else { throw HelperFailure(code: "TIMEOUT", message: "Another simulator is using the clipboard; retry after it finishes") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        Darwin.close(descriptor)
    }
}
