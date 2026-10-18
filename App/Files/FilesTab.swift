import AppKit
import DeviceCore
import SwiftUI
import UniformTypeIdentifiers

/// 「文件」标签（spec §3.5）：浏览设备目录，拉取到 Mac，推送 Mac 文件，拖到 Finder 即拉取。
struct FilesTab: View {
    let model: FilesModel
    let commands: DeviceCommands
    let deviceID: String

    @State private var pathText = ""
    @State private var selected: String?

    private var current: String { model.currentPath(deviceID) }
    private var listing: Result<[RemoteFile], DeviceError>? { model.listing[deviceID] }
    private var selectedFile: RemoteFile? {
        guard case .success(let files)? = listing else { return nil }
        return files.first { $0.path == selected }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.separator).frame(height: 1)
            content
        }
        .task(id: deviceID) {
            pathText = current
            selected = nil
            // 切回时已有列表就直接显示；首次进入才读取
            if model.listing[deviceID] == nil { await model.open(deviceID, current) }
        }
        .onChange(of: current) { _, new in
            pathText = new
            selected = nil
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button("上级") { Task { await model.up(deviceID) } }
                    .disabled(current == "/")
                TextField("路径", text: $pathText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.open(deviceID, pathText) } }
                Button("刷新") { Task { await model.refresh(deviceID) } }
            }
            HStack(spacing: 6) {
                ForEach(FilesModel.shortcuts, id: \.self) { path in
                    Button((path as NSString).lastPathComponent) { Task { await model.open(deviceID, path) } }
                }
            }
            HStack(spacing: 6) {
                Button("推送文件…") { pickAndPush() }
                Button("拉取") {
                    if let file = selectedFile { commands.pull(deviceID, file.path, origin: .workspace) }
                }
                .disabled(selectedFile.map { $0.kind == .directory } ?? true)
                if model.loading.contains(deviceID) { ProgressView().controlSize(.small) }
            }
        }
        .controlSize(.small)
        .padding(10)
    }

    // MARK: 列表

    @ViewBuilder private var content: some View {
        switch listing {
        case nil:
            Spacer()
        case .failure(let error)?:
            VStack(alignment: .leading, spacing: 4) {
                Text("无法读取目录").font(.callout.weight(.medium)).foregroundStyle(Theme.danger)
                Text(error.message).font(.caption).foregroundStyle(Theme.textSecondary)
                if let suggestion = error.suggestion {
                    Text(suggestion).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Spacer()
        case .success(let files)?:
            if files.isEmpty {
                Text("目录为空")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(files, id: \.path) { file in row(file) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func row(_ file: RemoteFile) -> some View {
        let view = FileRow(file: file, isSelected: selected == file.path)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { activate(file) }
            .onTapGesture { selected = file.path }
        if file.kind == .directory || file.kind == .symlink {
            view
        } else {
            view.onDrag { dragProvider(file) }
        }
    }

    /// 双击：目录（以及可能指向目录的符号链接，如 /sdcard）进入，文件拉取。
    private func activate(_ file: RemoteFile) {
        selected = file.path
        switch file.kind {
        case .directory, .symlink: Task { await model.open(deviceID, file.path) }
        case .file, .other: commands.pull(deviceID, file.path, origin: .workspace)
        }
    }

    /// 拖到 Finder：Finder 要数据时才拉取到临时目录，再由系统复制。
    private func dragProvider(_ file: RemoteFile) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = file.name
        let id = deviceID, remote = file.path, commands = commands
        provider.registerFileRepresentation(
            forTypeIdentifier: UTType.data.identifier, fileOptions: [], visibility: .all
        ) { completion in
            Task {
                do { completion(try await commands.pullToTemporary(id, remote), false, nil) } catch { completion(nil, false, error) }
            }
            return nil
        }
        return provider
    }

    private func pickAndPush() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "推送"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        commands.pushFiles(deviceID, panel.urls, dest: model.pushDestination(deviceID), origin: .workspace)
    }
}

/// 一行：名称、大小、修改时间。
private struct FileRow: View {
    let file: RemoteFile
    let isSelected: Bool

    private static let dateFormat = Date.FormatStyle(date: .numeric, time: .shortened)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: file.kind == .directory ? "folder" : "doc")
                .foregroundStyle(file.kind == .directory ? Theme.accent : Theme.textSecondary)
                .frame(width: 16)
            Text(file.name)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.kind == .directory ? "" : ByteCountFormatter.string(fromByteCount: Int64(clamping: file.size), countStyle: .file))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 64, alignment: .trailing)
            Text(file.modified.formatted(Self.dateFormat))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 100, alignment: .trailing)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
    }
}
