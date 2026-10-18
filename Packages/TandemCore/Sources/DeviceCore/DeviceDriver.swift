public protocol DeviceDriver: Sendable {
    func deviceSnapshots() -> AsyncStream<[DeviceInfo]>
    func makeSession(for device: DeviceInfo) -> any DeviceSession
}
