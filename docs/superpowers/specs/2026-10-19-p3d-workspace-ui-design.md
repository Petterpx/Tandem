# P3d 工作台界面对齐与截图提速设计文档

依据总设计 `docs/superpowers/specs/2026-10-17-tandem-design.md`（下称"总设计"）与设计稿 `docs/superpowers/design/mockups/`（从 claude.ai 设计画布「MagicDevX UI 原型」导出；`Workspace.dc.html` 为最终工作台方案）。本文件覆盖 P3d；与总设计冲突时以本文件为准，并同步回总设计。

逐区域的差异清单见附录 `2026-10-19-p3d-ui-gap-inventory.md`（下称"差异清单"），其中给出了每处设计数值与现有代码的 file:line。

## 1. 背景与范围

用户实测两个问题：

1. **点截图一卡一卡、有延迟。** 根因（已核实）：工作台截图走 `adb exec-out screencap -p`，手机端整屏 PNG 编码再经 USB 传回，SM-G9730 熄屏时单次已需 0.73 s，亮屏更久；期间没有任何反馈，按钮可连点排队；screencap 与 scrcpy 编码器争用手机 CPU 和 USB 带宽，投屏本身也会卡；数据回来后写文件与写剪贴板在主线程上。AI 截图已用投屏最新帧，没有这个问题。
2. **界面与设计稿不符。** 全部用系统默认控件，没有统一的按钮 / 卡片 / 开关样式；多处颜色偏差，正文字号普遍小 1–2 pt；缺手机外框、浮动工具条、卡片分组、左栏 App 头部等。

用户决定（2026-10-19）：

- 截图默认取投屏帧，另提供无损的「高清截图」。
- 界面对齐分两期，**P3d 只做工作台主窗口**；第二期（P3e）再做弹出窗口、设置、配对、日志窗口、粘贴弹窗、文件页内容、菜单栏。

不在 P3d：上述第二期窗口；任何新的设备能力；iOS。

## 2. 截图

### 2.1 两档

| 档位 | 触发 | 来源 | 结果 |
|---|---|---|---|
| 截图（默认） | 工具条「截图」按钮、菜单「设备 › 截图」⌘⇧S | 会话最新投屏帧 `session(id)?.latestFrame()`，原帧分辨率（USB 长边 1920，Wi-Fi 1280）编码为 PNG | 立即保存、写剪贴板、出提示条 |
| 高清截图 | 按住 ⌥ 点「截图」；菜单「设备 › 高清截图」⌥⌘⇧S | `adb exec-out screencap -p`（无损原分辨率） | 同上，约 1 s 后完成 |

- 会话没有画面（未投屏 / 连接中 / 失败）时，默认截图自动退回 screencap。
- 提示条副标题注明来源与尺寸：`<宽>×<高> · 投屏画质` 或 `<宽>×<高> · 无损`，后接现有的「已复制到剪贴板」。
- 操作记录文字不变（「截图」），高清为「高清截图」。
- AI 的 `screenshot` 工具行为不变。

### 2.2 不卡界面

- **防连点**：每台设备同一时间只跑一次截图；进行中再点直接忽略。高清截图进行中，「截图」按钮显示小转圈并禁用。
- **编码、写文件、生成缩略图都在主线程之外**：帧 → PNG 编码、`Data.write(.atomic)`、目录创建与重名检查、长边 256 的缩略图 PNG，在一个 `Task.detached` 中完成；回到主线程只做加入最近记录、写剪贴板、出提示条。
- 缩略图在保存时生成一次，存入 `CaptureItem.thumbnailPNG`；提示条与最近截图条直接用它，不再各自解码整图。
- 剪贴板仍同时写 PNG 数据与文件 URL（行为不变）。

## 3. 设计语言（全局）

数值全部取自 `Workspace.dc.html`；深色外观沿用 `Theme.dynamic` 现有的派生方式（中性色按明度翻转后压暗，强调 / 状态色略提亮），每个新颜色都要给深色值。

### 3.1 颜色

| Token | 浅色 | 用途 |
|---|---|---|
| windowBackground | #FFFFFF | 主内容区、顶栏下的头部、底部两栏 |
| titleBar | #F6F6F8 | 标题栏区域（如有自绘） |
| sidebar | #F4F4F6 | 左栏 |
| panel | #FBFBFC | 右栏 |
| canvas | #EEF0F3 | 投屏画布 |
| canvasDot | #000000 @ 5% | 画布点阵，间距 20 |
| border | #E5E5EA | 区域分隔线 |
| cardBorder | #E8E8ED | 卡片描边 |
| controlBorder | #D8D8DD | 按钮 / 输入框描边 |
| rowDivider | #F0F0F3 | 卡片内行分隔 |
| hover | #000000 @ 4% | 行悬停 |
| controlHover | #F2F2F5 | 次要按钮悬停 |
| textPrimary | #1D1D1F | |
| textSecondary | #6E6E73 | |
| textTertiary | #3A3A3C | 芯片文字 |
| accent | #2F6FED | |
| accentStrong | #2459C9 | 链接、主按钮悬停、强调芯片文字 |
| accentTint / accentTintBorder | #EEF2FF / #D9E3FB | 「已弹出」「你」芯片、信息卡 |
| aiTint / aiText | #F3EEFF / #6B4FD8 | 「AI」芯片 |
| chipNeutral | #EDEDF0 | 中性芯片 |
| chipCount | #E5E5EA | 计数芯片 |
| success / successTint / successText | #1F9D55 / #E8F5EE / #146C3B | 状态点、「实时」胶囊 |
| danger | #D93025 | 错误、录屏中 |
| dotOff | #AEAEB2 | 未授权 / 不支持的空心点 |
| toggleOff / toggleDisabled | #D1D1D6 / #E5E5EA | 开关轨道 |
| warnTint / warnBorder / warnText | #FFF6E0 / #F1E0B0 / #7A5200 | ROM 横幅 |
| bezel | #1C1C1E | 手机外框 |
| dashed | #C7C7CC | 拖放区虚线 |

现有 token 改值：sidebar、canvas、canvasDot、textPrimary、textSecondary、success 按上表；`separator` 并入 `border`（#E5E5EA）。`bannerBackground` / `bannerText` 被 warn 系列取代。

### 3.2 字号与尺寸

- 字号（pt）：区块标题 11 semibold，字距 0.44；正文 / 行标签 13；按钮与次要正文 12；元信息 11；芯片 10；等宽 12（`.system(size:12, design:.monospaced)`）。不再用 `.caption` / `.callout` 这类语义字号（macOS 上分别是 10 / 12，偏小）。
- 圆角：卡片 10、按钮 8、左栏行 9、芯片 8、浮动工具条 12。
- 高度：按钮 30、图标按钮 30×30、开关 36×20（滑块 16）、卡片行最小 34、设备头部 48。
- 布局：左栏固定 232、右栏固定 372、底部两栏高 168，操作记录栏宽 372 并与右栏对齐。不再可拖动分栏。
- 卡片：白底、1 px cardBorder、圆角 10、阴影 `0 1 2 rgba(0,0,0,.04)`。区块间距 20，标题与卡片间距 8。

### 3.3 共用组件

在 `App/Style/` 下新建，工作台所有区域只用这些组件，不再直接用 `.bordered` / `.switch` / `.segmented` 等系统样式：

- `SectionHeader(title, badge:, trailing:)`
- `.tandemCard(padding:)`
- `CardRow(label, subtitle:) { 尾部控件 }`
- `TandemButtonStyle(.secondary / .primary / .icon / .link)`：悬停变色，禁用时不透明度 0.45。
- `TandemSwitchStyle`：36×20 开关。
- `Chip(text, tone: .accent / .neutral / .ai / .success / .count)`、`StatusDot(size:, filled:)`
- `TandemFieldStyle(mono:)`：30 高、圆角 8、controlBorder 描边。
- `UnderlineTabs`：间距 18、高 32、选中项 600 字重加 2 px 强调色下划线。
- `FlowLayout`：自动换行排列芯片和按钮。
- `PhoneBezel`：外框 7、外圆角约为宽度的 15%、阴影 `0 20 40 rgba(16,24,40,.12)`。
- `ToolbarPill`：内边距 6、圆角 12、白底 85%、cardBorder 描边。
- `DotGrid(spacing: 20)`

## 4. 各区域（P3d）

具体数值与现有代码位置见差异清单 §1–§6。要点如下。

1. **窗口**：标题为「Tandem · <当前设备名>」，没有选中设备时为「Tandem」。
2. **左栏**：
   - 头部：30 px App 图标，加「Tandem」（14 bold）和「同驾 · 你和 AI 一起驾驶测试机」（11 secondary）。
   - 「设备」标题后跟计数芯片。
   - 自绘设备行：手机轮廓图标；名称（选中 600）；「已弹出」芯片；副标题行带 6 px 状态点。
   - 选中行为白底卡片加阴影，悬停 4% 黑。未授权行不透明度 0.55。
   - 悬停时右侧出现 26×26 弹出按钮。
   - 保留现有右键菜单、锁定与录屏指示（改为行尾小图标）、↑ / ↓ 键切换选中。
   - 底部「无线配对…」「设置」两个整宽左对齐按钮，上下排列。
3. **设备头部**：
   - 48 高白底，单行：名称 14 bold，元信息 12 secondary（平台与版本 · 分辨率 · 连接方式，缺哪项省哪项）。
   - 状态胶囊：投屏中为绿色「实时」；连接中、失败、断开沿用现有文案，套中性或危险色胶囊。
   - 右侧次要按钮：「弹出为独立窗口」，弹出后变为「收回独立窗口」。
4. **投屏区**：
   - 画布 #EEF0F3 加 20 px 淡点阵。
   - 画面套 `PhoneBezel`，外框在 `VideoSurface` 之外，内屏裁圆角；输入坐标映射不受影响。
   - 下方 12 px 处放 `ToolbarPill`：
     - Android 为返回、主页、多任务三个 30×30 图标按钮。
     - 一条分隔线。
     - 「截图」「录屏」两个图标加文字按钮；录屏中显示「停止 mm:ss」，危险色。
5. **右栏**：
   - 头部：「设备控制」（13 semibold）加设备名（12 secondary），下方 `UnderlineTabs`：快捷操作 / 文件 / 剪贴板 / AI。文件页只换标签样式，内容留到 P3e。
   - 快捷操作页：
     - 按设计顺序排列：网络、应用、打开链接、系统、开发者、自定义命令、能力概览。
     - 每块是 `SectionHeader` 加卡片。「该设备不支持」改为标题旁的中性芯片。
     - 刷新改为标题行尾的 11 pt 次要图标。折叠箭头保留，同样放在行尾。
     - 网络卡片下方加「恢复默认网络」次要按钮：依次关闭飞行模式、打开 Wi-Fi 和移动数据，只执行设备支持的项。
     - 应用卡片：「当前前台」标签，包名用 13 pt 等宽字体；操作按钮排成等宽网格，替代表情和图钉。
     - 应用卡片下方是 74 高的虚线拖放区，文案「拖入 APK 安装 / 其他文件推送到 /sdcard/Download」。点击打开文件选择，选 APK 走安装，其他文件走推送，都复用现有命令。
     - 拖放区下方「查看日志」链接。
     - 打开链接：输入框加主按钮「打开」，历史记录改为可换行芯片。
     - 能力概览：标题为「能力概览 · <设备名>」，卡片行用实心或空心状态点，加「支持 / 不支持」文字。
   - 剪贴板页、AI 页：按差异清单 §4 改为卡片加开关行；「双向自动同步」「禁止 AI 操作」用 `TandemSwitchStyle`，不再是复选框。
6. **底部两栏**：
   - 最近截图：
     - 标题加计数，再加「清空」链接。
     - 每格 120 宽，下方标签「<设备名> · HH:mm」。
     - 截图缩略图高 92、圆角 6；录屏为深色块，加播放图标和时长角标。
     - 悬停时浮层显示「拷贝」「在 Finder 中显示」两个 28 高按钮。
   - 操作记录：
     - 副标题「你和 AI 的所有操作」。
     - 每行依次是时间（11 pt 等宽）、身份芯片、单行省略文字。芯片配色：你为 accentTint / accentStrong，AI 为 aiTint / aiText。
     - 文字形如「设备名 · 动作」，错误用危险色。
7. **提示条**：
   - 位置在投屏区顶部居中、设备头部下方。宽 320–560，白底，cardBorder 描边，圆角 12，阴影 `0 12 32 rgba(16,24,40,.16)`。
   - 左侧 22 px 圆形图标，错误时用危险色；标题 13 semibold，副标题 11 等宽。
   - 显示 2.8 s，悬停时暂停计时。保留缩略图和拖出。
8. **ROM 横幅**：
   - 改为画布顶部一行：左右各留 16，内边距 9/12，圆角 10，warn 配色，12 pt，三角图标。
   - 行尾是「查看步骤」链接和关闭按钮。关闭只对本次会话的该设备生效。
   - 步骤移到一个 sheet，内容与按钮按 `RomBanner.dc.html` 的右侧：按品牌分卡片，底部「稍后」和主按钮「已打开，重新检测」，后者复用现有检测。
9. **传输进度条**：
   - 改为投屏列底部的 42 高白条，带顶部描边。
   - 内容：12 pt 文案、6 px 自绘进度轨道、40 宽右对齐的等宽百分比。
   - 不再盖在画面上。
10. **拖放遮罩**：
    - 强调色 12% 底，加 2 px 虚线强调色描边，圆角与屏幕一致。
    - 居中一张白色提示卡：图标加 13 semibold 文案，文案沿用现有。

## 5. 验证

- 单元测试覆盖：截图两档的选择逻辑与退回、防连点、主线程外保存、缩略图生成、新增策略函数（如「恢复默认网络」要执行的动作、设备头部元信息拼接、标题拼接）。
- **界面快照**：用 `ImageRenderer` 把各区域（纯 SwiftUI、注入假数据）渲染成 PNG，写到 `NSTemporaryDirectory()/tandem-snapshots/`，供评审对照设计稿目视检查。这些测试不比较像素，只断言能渲染出非空图像。`VideoSurface` 等 AppKit 包装视图用占位色块代替。
- App 测试一律用 `-derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/Tandem-p3c-tests"`。不用 `open` 启动 App，也不退出用户正在运行的 Tandem。
- 真机：不需要新的设备测试。手动验收清单 `docs/superpowers/qa/p3d-manual-checklist.md` 覆盖：截图即时出图、高清截图、截图时投屏不卡、各区域外观与设计稿对照。
