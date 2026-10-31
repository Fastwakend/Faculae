# 1.14.2 灵动岛展开留白与安全边距

版本：1.14.2（22）。保留此前的搜索、附件、系统权限和可选诊断记录功能。

## 截图反馈与原因

本次用户截图中，Logo、Flash 名称、0:29 计时、“实时活动显示测试”状态和 123 tokens 均已出现；主要问题是展开面板上部存在明显的黑色空白，内容集中在下半部。

上一版将所有展开内容放进 DynamicIslandExpandedRegion(.bottom)。根据 Apple 文档，bottom 位于 leading、trailing 和 center 下方；即使其他区域未填入内容，传感器周围仍有系统保留空间。上一版又对底部内容设置了最小 48pt 高度和 4pt 顶部 padding，进一步增加了面板高度。这是本次改版针对的布局问题，截图中没有看到额外绘制的黑色遮罩。

灵动岛的黑色外形和传感器避让由 iOS 管理，App 不能将硬件区域变为透明，也不应让文字侵入该区域。本版通过公开 WidgetKit API 调整内容和边距，不绘制额外的背景或遮罩。

## 布局

- leading：20pt Logo、14pt 模型显示名称，以及 11.5pt 次级回复状态。
- trailing：14pt 等宽计时，以及 11.5pt tokens，右侧整列明确保留 92pt，避免计时文本固有宽度不确定导致消失。
- 不再创建 bottom 区域；移除上一版的最小高度和额外顶部 padding，让实际内容决定高度。
- 两列行间距为 4pt，展开内容横向安全边距 18pt、纵向 10pt，使用 DynamicIsland.contentMargins 设置。
- 名称和状态最多两行，允许适度缩放。左侧最大宽度 176pt，使用系统 belowIfTooWide，在传感器两侧确实放不下时允许下移，优先保证内容可读和传感器避让。
- 紧凑状态、最小状态、锁屏卡片、计时更新方式和诊断开关不变。

系统最终的外形、高度和传感器周围留白仍取决于设备与内容；没有承诺所有设备均为同一固定高度，也没有为追求变矮而隐藏状态或 tokens。

## 官方依据

2026-10-30 核对了 iOS 27.2 SDK 声明及 Apple 文档：

- [DynamicIslandExpandedRegion](https://developer.apple.com/documentation/widgetkit/dynamicislandexpandedregion)：leading/trailing 位于 TrueDepth 相机两侧，可向下延伸；bottom 位于其下方。
- [contentMargins](https://developer.apple.com/documentation/widgetkit/dynamicisland/contentmargins(_:_:for:))：可为展开区域设置内容边距，文档要求避免内容紧贴外缘。

## 验证与边界

- 63 个 Swift 文件静态解析、工程引用与资源检查通过。
- 89 项核心 XCTest 通过；主应用及实时活动扩展通过 iOS arm64 Release 编译与链接。
- IPA 版本、资源、CRC、iOS 27.2 SDK 元数据及 `_NSExtensionMain` 扩展入口检查通过。主应用无编译警告；扩展仍有此前的 LLD iOS 平台支持警告。
- 与构建副本逐字节核对 163 个输入文件一致；网页渲染资源未改动，不重复运行先前的 24 项桌面渲染检查。
- 没有可运行的 iOS Simulator 或连接的 iPhone；源码和编译验证不能代替 WidgetKit 的实际布局验收。安装后可用“后台生成 → 测试灵动岛与锁屏显示”核对短名称、长名称、状态、计时和 tokens，结束测试后再测试真实生成任务。

IPA 未签名，主应用和 SeekActivity 扩展需要一起签名安装。
