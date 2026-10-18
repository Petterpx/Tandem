import SwiftUI
import UniformTypeIdentifiers

/// ⌘V 粘贴文件的确认框（spec §3.3）。
struct PasteFilesSheet: View {
    let files: [PasteFile]
    let recents: [String]
    /// 设备支持安装 APK；否则不显示 APK 选项。
    let canInstall: Bool
    let onConfirm: (PasteChoice, _ remember: Bool) -> Void
    let onCancel: () -> Void

    private static let fixedDirectories = [
        ("Download", "/sdcard/Download/"), ("Pictures", "/sdcard/Pictures/"),
        ("DCIM", "/sdcard/DCIM/"), ("Documents", "/sdcard/Documents/"),
    ]

    @State private var dest = "/sdcard/Download/"
    @State private var installAPK = true
    @State private var mediaScan = true
    @State private var conflict = ConflictPolicy.rename
    @State private var heicToJPEG = false
    @State private var remember = false

    private var hasAPK: Bool { canInstall && files.contains(where: PasteFlow.isAPK) }
    private var hasHEIC: Bool { files.contains { $0.format == "HEIC" } }
    private var hasTIFF: Bool { files.contains { $0.origin == .tiffConverted } }
    private var hasMedia: Bool { files.contains(where: Self.isMedia) }

    /// 最近目录去掉与固定四项重复的（比较时忽略结尾的 `/`）。
    private var extraRecents: [String] {
        let fixed = Set(Self.fixedDirectories.map { Self.normalized($0.1) })
        return recents.filter { !fixed.contains(Self.normalized($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(files.count == 1 ? "推送到设备" : "推送 \(files.count) 个文件到设备").font(.headline)
            fileList
            if hasTIFF { note("原始为 TIFF，已无损转为 PNG") }
            if hasHEIC {
                Toggle("转为 JPEG", isOn: $heicToJPEG)
                note("HEIC 部分 Android 设备无法预览")
            }
            if hasAPK {
                Picker("APK", selection: $installAPK) {
                    Text("安装").tag(true)
                    Text("仅推送").tag(false)
                }
                .pickerStyle(.segmented)
            }
            Picker("目标目录", selection: $dest) {
                ForEach(Self.fixedDirectories, id: \.1) { Text($0.0).tag($0.1) }
                if !extraRecents.isEmpty {
                    Divider()
                    ForEach(extraRecents, id: \.self) { Text($0).tag(Self.directory($0)) }
                }
            }
            if hasMedia { Toggle("图片和视频加入相册", isOn: $mediaScan) }
            Picker("同名文件", selection: $conflict) {
                Text("自动改名").tag(ConflictPolicy.rename)
                Text("覆盖").tag(ConflictPolicy.overwrite)
            }
            .pickerStyle(.segmented)
            Toggle("记住选择，以后不再询问", isOn: $remember)
            HStack {
                Spacer()
                Button("取消", action: onCancel).keyboardShortcut(.cancelAction)
                Button("推送") {
                    onConfirm(
                        PasteChoice(dest: dest, installAPK: installAPK, mediaScan: mediaScan, conflict: conflict,
                                    heicToJPEG: heicToJPEG),
                        remember)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var fileList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(files[i].name).lineLimit(1).truncationMode(.middle)
                        Text(Self.detail(files[i])).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxHeight: 120)
        .padding(8)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 6))
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textSecondary)
    }

    /// `大小 · 格式 · 来源`
    static func detail(_ file: PasteFile) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        let origin = switch file.origin {
        case .file: "文件"
        case .rawData: "原始数据"
        case .tiffConverted: "TIFF 转 PNG"
        }
        return "\(size) · \(file.format) · \(origin)"
    }

    private static func isMedia(_ file: PasteFile) -> Bool {
        if file.format == "文件夹" { return true }  // 文件夹里可能有图片、视频
        guard let type = UTType(filenameExtension: file.url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// 推送目标目录以 `/` 结尾。
    private static func directory(_ path: String) -> String { path.hasSuffix("/") ? path : path + "/" }

    private static func normalized(_ path: String) -> String {
        path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
