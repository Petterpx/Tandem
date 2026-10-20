import SwiftUI

/// 6 pt 高的进度轨道：灰底、强调色填充；`fraction` 为 nil 时只画轨道。
struct ProgressTrack: View {
    let fraction: Double?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3)
        shape.fill(Theme.border)
            .overlay(alignment: .leading) {
                if let fraction {
                    GeometryReader { proxy in
                        shape.fill(Theme.accent)
                            .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
            }
            .frame(height: 6)
    }
}
