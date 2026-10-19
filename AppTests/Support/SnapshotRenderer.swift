import AppKit
import SwiftUI
@testable import Tandem

/// 把视图渲染成浅色 / 深色两张 PNG，供评审目视对照设计稿。
@MainActor
enum SnapshotRenderer {
    struct RenderError: Error { let name: String }

    static let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("tandem-snapshots")

    @discardableResult
    static func render<V: View>(_ name: String, size: CGSize, @ViewBuilder _ view: () -> V) throws -> CGImage {
        let content = view()
            .frame(width: size.width, height: size.height)
            .background(Theme.windowBackground)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let light = try image(of: content, name: name)
        try write(light, to: directory.appendingPathComponent("\(name).png"))

        var dark: CGImage?
        var failure: Error?
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            do { dark = try image(of: content.environment(\.colorScheme, .dark), name: name) } catch { failure = error }
        }
        if let failure { throw failure }
        try write(dark!, to: directory.appendingPathComponent("\(name)-dark.png"))
        return light
    }

    private static func image<V: View>(of view: V, name: String) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage else { throw RenderError(name: name) }
        return image
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError(name: url.lastPathComponent) }
        try data.write(to: url)
    }
}
