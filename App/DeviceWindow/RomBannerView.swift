import SwiftUI
import AndroidDriver

struct RomBannerView: View {
    let guide: RomGuide
    let onReconnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("无法注入点击：需要额外开启调试权限").font(.headline)
            Text(guide.brand).font(.subheadline).foregroundStyle(.secondary)
            ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                Text("\(index + 1). \(step)").font(.callout)
            }
            HStack {
                Text("以手机上的实际选项为准").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("已打开，重新连接", action: onReconnect)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warnTint, in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(Theme.warnText)
        .padding(8)
    }
}
