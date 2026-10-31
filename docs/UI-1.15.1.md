# 1.15.1（24）：推理菜单重影与连续开关

## 反馈与证据

用户在 iOS 27.2 的截图中看到推理按钮关闭时出现双层胶囊和重复的 Medium 文字，并反馈开关掉帧、一次关闭后要等待才能再次打开。

1.15.0 的实现同时包含输入栏原按钮和全屏 overlay 的模拟按钮，靠原按钮 opacity 切换可见性。每次打开重新创建 overlay、GlassEffectContainer、namespace 和 Slider，延迟 20ms 后开始动画；关闭设置 `closing` 锁，并等待弹簧动画的 `.removed` completion 才销毁 overlay、恢复原按钮。这个生命周期包含两套按钮，以及阻止反向操作的等待路径。

这些是源码中已确认的结构和等待条件，与截图及点击反馈吻合。没有本机 iOS 运行环境或设备性能 trace，不能据此认定唯一的设备渲染原因，也没有测得修复前后的 FPS。

## 改动

- iOS 26+ 输入栏的推理位置只保留无玻璃、无交互的文字布局占位；唯一可见、可点的推理按钮由常驻 overlay 提供。动态宽度与底部控件排列保留。
- 常驻 `GlassEffectContainer` 与 namespace 在开关之间保留。显示状态只由 `showsReasoning` 的 Binding 决定，移除额外的 `expanded` / `closing` 状态、Task 延迟和动画完成回调。
- 点击空白处关闭时，遮罩与面板内容立即停止命中测试，收起目标按钮立即可点。不用等待弹簧尾部结束，再次点击直接改变同一个状态，交给原生玻璃动画反向过渡。
- 原生 `glassEffect` / `glassEffectID` / `glassEffectTransition(.matchedGeometry)` 只负责外形变形。Slider 和菜单文字保持在面板最终位置，打开时短暂淡入，关闭时立即隐藏，不再跟随玻璃一起折叠进按钮。
- 只保留一个常驻 `ReasoningSettings` 和原生 Slider，移除 ViewThatFits 的双分支内容。内容高度预先测量并用于滚动容器，避免每次开关重新创建和探测 Slider；空间不足时仍能滚动。
- 玻璃弹簧调整为 response 0.30、dampingFraction 0.86，减少长尾震荡。动画局限于玻璃表面，保留“减弱动态效果”支持。
- 面板宽度上限仍为 360pt、水平居中并覆盖输入区域。只参考按钮底边，等级文字宽度变化不会横向推动面板；键盘和窗口高度改变时仍可更新垂直位置。
- 显示按钮按原横向控件栏的可见范围裁切，命中区域限制在可见交集，避免长模型名称使按钮覆盖右侧附件或发送按钮。
- 打开菜单不再自动写入推理参数或同步保存整份聊天记录；只有用户选择档位时修改设置。滑块重复返回同一个归一化档位时直接返回，避免重复持久化。
- iOS 17–25 保留原生 popover 回退。系统分享、实时活动、头像、竖屏锁定及其它功能保留。

## 验证

- 68 个 Swift 文件静态解析及 Xcode 引用检查通过。
- 89 项核心 XCTest、10 项分享文件队列测试重新执行并通过。
- 主 App、实时活动扩展与分享扩展完成 iOS arm64 Release 编译和链接；主 App 无编译警告，WSL 扩展链接器仍有既有平台支持警告。
- IPA 版本、SDK 27.2 元数据、原生玻璃/Slider 符号、两个扩展入口及 ZIP CRC 检查通过。
- 桌面渲染资源没有改动；1.15.0 的 25 项桌面渲染结果保留为先前验证，本次不重复运行。
- 没有新增只检查布尔切换或源代码字符串的“动画测试”；这类测试无法捕获实际 SwiftUI 合成重影或掉帧。未执行 iPhone/Simulator UI 运行和 Instruments 采样。

安装后需重点验证：连续快速开关 20 次、关闭尚未收完就再次点击、打开未完成就点空白关闭、拖动 Slider 后关闭、键盘显示时打开，以及长模型名称横向滚动后点击。确认关闭无双层按钮、没有点击等待、控件栏其它按钮可用，并检查浅色、深色与减弱动态效果。

## 官方接口依据

2026-10-30 核对了 Apple 文档：

- [AnimationCompletionCriteria.removed](https://developer.apple.com/documentation/swiftui/animationcompletioncriteria/removed)：整个动画完成并移除后才触发，旧实现用它控制交互释放。
- [GlassEffectTransition.matchedGeometry](https://developer.apple.com/documentation/swiftui/glasseffecttransition/matchedgeometry)：继续使用原生玻璃匹配几何过渡。
