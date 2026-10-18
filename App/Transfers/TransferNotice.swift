import Foundation

/// 「在文件中查看」的目标：设备与设备上的路径（文件页打开该路径所在目录）。
struct RevealTarget: Equatable {
    var deviceID: String
    var path: String
}

/// 传输结束后的提示内容。
struct TransferNotice: Equatable {
    var title: String
    var detail: String?
    var isError: Bool
    var revealPath: RevealTarget?

    /// 已完成或失败的项转为提示；取消与未结束的项没有提示。
    static func from(_ job: TransferJob) -> TransferNotice? {
        switch job.state {
        case .waiting, .running, .cancelled:
            return nil
        case .failed(let error):
            return TransferNotice(title: "\(job.kind.title) 失败", detail: error.message, isError: true, revealPath: nil)
        case .done(let result):
            switch result {
            case .pushed(let paths):
                guard let first = paths.first else { return nil }
                let title = paths.count == 1
                    ? "已推送到 \(first)"
                    : "已推送 \(paths.count) 个文件到 \((first as NSString).deletingLastPathComponent)"
                return TransferNotice(
                    title: title, detail: job.note, isError: false,
                    revealPath: RevealTarget(deviceID: job.deviceID, path: first))
            case .installed(let package):
                return TransferNotice(
                    title: package.map { "已安装 \($0)" } ?? "安装成功", detail: job.note, isError: false, revealPath: nil)
            case .pulled(let url):
                return TransferNotice(title: "已拉取到 \(url.path)", detail: job.note, isError: false, revealPath: nil)
            }
        }
    }
}
