import SwiftUI
import CoreImage.CIFilterBuiltins
import DeviceCore
import AndroidDriver

struct PairingView: View {
    let model: AppModel

    @State private var credentials = Self.makeCredentials()
    @State private var status = "等待扫码…"
    @State private var failed = false
    @State private var pairingTask: Task<Void, Never>?
    @State private var hostPort = ""
    @State private var code = ""
    @State private var switching: Set<String> = []
    @State private var switchMessage: String?

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            leftColumn.frame(maxWidth: .infinity, alignment: .top)
            Divider()
            rightColumn.frame(width: 240, alignment: .top)
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 460)
        .onAppear { restartQRPairing() }
        .onDisappear {
            pairingTask?.cancel()
            pairingTask = nil
        }
    }

    // MARK: - 左栏

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let image = Self.qrImage(for: credentials.qrPayload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: image.size.width, height: image.size.height)
                    .accessibilityLabel("无线调试配对二维码")
            }
            Text("手机打开 开发者选项 → 无线调试 → 使用二维码配对设备")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(status)
                .foregroundStyle(failed ? Color.red : Color.primary)
            if failed {
                Button("重新生成二维码") { restartQRPairing() }
            }
            Divider()
            GroupBox("手动输入配对码") {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("IP 地址和端口") {
                        TextField("", text: $hostPort, prompt: Text("192.168.1.23:37099"))
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent("配对码") {
                        TextField("", text: $code, prompt: Text("6 位数字"))
                            .textFieldStyle(.roundedBorder)
                    }
                    Button("配对并连接") { startCodePairing() }
                        .disabled(hostPort.isEmpty || code.isEmpty || model.wirelessConnector == nil)
                }
                .padding(4)
            }
        }
    }

    // MARK: - 右栏

    private var usbDevices: [DeviceInfo] {
        model.devices.filter { $0.connection == .usb && $0.state == .connected }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("一键转无线").font(.headline)
            if usbDevices.isEmpty {
                Text("没有通过 USB 连接的设备").foregroundStyle(.secondary)
            }
            ForEach(usbDevices) { device in
                HStack {
                    Text(device.name).lineLimit(1)
                    Spacer()
                    Button("转为无线") { switchToWireless(device.id) }
                        .disabled(switching.contains(device.id) || model.wirelessConnector == nil)
                }
            }
            if let switchMessage {
                Text(switchMessage).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 行为

    private func restartQRPairing() {
        pairingTask?.cancel()
        credentials = Self.makeCredentials()
        failed = false
        status = "等待扫码…"
        guard let connector = model.wirelessConnector else { return }
        let creds = credentials
        pairingTask = Task {
            do {
                _ = try await connector.pairWithQR(creds) { step in
                    Task { @MainActor in apply(step) }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func startCodePairing() {
        guard let connector = model.wirelessConnector else { return }
        pairingTask?.cancel()
        failed = false
        let target = hostPort.trimmingCharacters(in: .whitespaces)
        let pairCode = code.trimmingCharacters(in: .whitespaces)
        pairingTask = Task {
            do {
                _ = try await connector.pairWithCode(hostPort: target, code: pairCode) { step in
                    Task { @MainActor in apply(step) }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                fail(error)
            }
        }
    }

    private func switchToWireless(_ serial: String) {
        guard let connector = model.wirelessConnector else { return }
        switching.insert(serial)
        switchMessage = nil
        Task {
            defer { switching.remove(serial) }
            do {
                let target = try await connector.switchToWireless(serial: serial)
                switchMessage = "已连接 \(target)"
            } catch {
                switchMessage = Self.message(for: error)
            }
        }
    }

    private func apply(_ step: WirelessStep) {
        failed = false
        switch step {
        case .waitingForScan: status = "等待扫码…"
        case .pairing: status = "正在配对…"
        case .connecting: status = "正在连接…"
        case .connected(let serial): status = "已连接 \(serial)"
        }
    }

    private func fail(_ error: Error) {
        failed = true
        status = Self.message(for: error)
    }

    private static func message(for error: Error) -> String {
        guard let e = error as? DeviceError else { return error.localizedDescription }
        return e.suggestion.map { "\(e.message)（\($0)）" } ?? e.message
    }

    // MARK: - 二维码

    private static func makeCredentials() -> PairingCredentials {
        var rng = SystemRandomNumberGenerator()
        return PairingCredentials.generate(using: &rng)
    }

    /// 生成二维码并按整数倍放大（配合 .interpolation(.none) 保持边缘锐利）。
    private static func qrImage(for text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let extent = output.extent
        let scale = max(1, Int(240 / extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
