import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct StyleGallerySnapshotTests {
    private struct StyleGallery: View {
        enum Tab: Hashable { case a, b, c }
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("次要") {}.buttonStyle(TandemButtonStyle(.secondary))
                    Button("主要") {}.buttonStyle(TandemButtonStyle(.primary))
                    Button { } label: { Image(systemName: "camera") }.buttonStyle(TandemButtonStyle(.icon))
                    Button("链接") {}.buttonStyle(TandemButtonStyle(.link))
                    Button("禁用") {}.buttonStyle(TandemButtonStyle(.secondary)).disabled(true)
                }
                HStack {
                    Toggle("on", isOn: .constant(true)).toggleStyle(TandemSwitchStyle()).labelsHidden()
                    Toggle("off", isOn: .constant(false)).toggleStyle(TandemSwitchStyle()).labelsHidden()
                    Toggle("disabled", isOn: .constant(true)).toggleStyle(TandemSwitchStyle()).labelsHidden().disabled(true)
                }
                HStack {
                    Chip("强调", tone: .accent)
                    Chip("中性", tone: .neutral)
                    Chip("AI", tone: .ai)
                    Chip("成功", tone: .success)
                    Chip("危险", tone: .danger)
                    Chip("3", tone: .count)
                    Chip("实时", tone: .success, dot: true)
                }
                HStack {
                    StatusDot()
                    StatusDot(filled: false)
                }
                SectionHeader("网络", badge: Chip("该设备不支持", tone: .neutral))
                VStack(spacing: 0) {
                    CardRow("无线调试", subtitle: "端口 5555") { Chip("开", tone: .success) }
                    CardDivider()
                    CardRow("代理") { Text("无").tandemText(.meta) }
                }
                .tandemCard()
                Text("https://").tandemField(mono: true)
                UnderlineTabs([(tab: Tab.a, title: "命令"), (tab: Tab.b, title: "文件"), (tab: Tab.c, title: "日志")], selection: .constant(.a))
                FlowLayout {
                    ForEach(0..<6, id: \.self) { Chip("标签\($0)", tone: .neutral) }
                }
                .frame(width: 200, alignment: .leading)
                DotGrid().frame(width: 200, height: 80).background(Theme.canvas)
                HStack(alignment: .top) {
                    Theme.videoBackground.frame(width: 80, height: 160)
                        .clipShape(BezelScreenShape())
                        .phoneBezel()
                    ToolbarPill {
                        Button { } label: { Image(systemName: "camera") }.buttonStyle(TandemButtonStyle(.icon))
                        Button { } label: { Image(systemName: "record.circle") }.buttonStyle(TandemButtonStyle(.icon))
                        Button { } label: { Image(systemName: "rotate.right") }.buttonStyle(TandemButtonStyle(.icon))
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @Test func primitives() throws {
        let image = try SnapshotRenderer.render("style-primitives", size: CGSize(width: 420, height: 720)) {
            StyleGallery()
        }
        #expect(image.width == 840 && image.height == 1440)
    }
}
