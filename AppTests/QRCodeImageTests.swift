import AppKit
import Testing
@testable import MagicDevX

@Suite struct QRCodeImageTests {
    /// 解出图片像素，返回 (宽, 高, 是否为深色模块像素, 是否为不透明白色像素)。
    private func pixels(_ image: CGImage) -> (Int, Int, (Int, Int) -> Bool, (Int, Int) -> Bool) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let snapshot = data
        return (w, h, { x, y in
            let i = (y * w + x) * 4
            return snapshot[i] < 128 && snapshot[i + 3] > 128
        }, { x, y in
            let i = (y * w + x) * 4
            return snapshot[i] == 255 && snapshot[i + 1] == 255 && snapshot[i + 2] == 255 && snapshot[i + 3] == 255
        })
    }

    @Test func hasAtLeastFourModulesOfOpaqueWhiteQuietZone() throws {
        let image = try #require(QRCodeImage.make(for: "WIFI:T:ADB;S:studio-abcdefghij;P:123456789012;;", targetWidth: 240))
        let (w, h, dark, white) = pixels(image.cgImage)
        let scale = image.moduleSize
        #expect(scale >= 1)
        let firstDarkColumn = (0..<w).first { x in (0..<h).contains { dark(x, $0) } }
        let lastDarkColumn = (0..<w).last { x in (0..<h).contains { dark(x, $0) } }
        let firstDarkRow = (0..<h).first { y in (0..<w).contains { dark($0, y) } }
        let lastDarkRow = (0..<h).last { y in (0..<w).contains { dark($0, y) } }
        #expect(try #require(firstDarkColumn) >= 4 * scale)
        #expect(w - 1 - (try #require(lastDarkColumn)) >= 4 * scale)
        #expect(try #require(firstDarkRow) >= 4 * scale)
        #expect(h - 1 - (try #require(lastDarkRow)) >= 4 * scale)
        // 静区是不透明白色（不依赖窗口背景色），且整幅图按整数倍放大。
        #expect(white(0, 0) && white(w - 1, h - 1) && white(4 * scale - 1, h / 2))
        #expect(w % scale == 0 && h % scale == 0)
    }
}
