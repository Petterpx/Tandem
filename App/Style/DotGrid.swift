import SwiftUI

/// 画布背景的淡点阵。
struct DotGrid: View {
    var spacing: CGFloat = 20
    var radius: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(Theme.canvasDot))
        }
        .allowsHitTesting(false)
    }
}
