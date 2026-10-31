# 1.3.1 (5)：系统菜单与滑条采用现代原生外观

## 原因与修复

用户真机截图中的推理面板和 Slider 呈现旧系统外观。检查上一版 IPA 后，发现其 Mach-O `LC_BUILD_VERSION` 中最低系统与链接 SDK 都被写成 `17.0`。虽然实际使用了 iPhoneOS 27.2 SDK，且显式的 `glassEffect` 已链接，错误的链接 SDK 元数据仍可能让系统标准菜单和控件采用旧版兼容外观。仅检查原生符号不足以发现这个问题，之前的验证遗漏了这一项。

Windows / WSL 构建脚本现在读取实际 Apple SDK 的 `SDKSettings.json`，通过环境变量传给 SwiftPM manifest，再明确向 Linux 链接器传入 `-platform_version ios 17.0 <实际SDK版本>`。1.3.1 的主程序实际为最低系统 `17.0.0`、链接 SDK `27.2.0`。没有修改编译完成的二进制，也没有提高最低系统版本；Mac / Xcode 构建继续由 Xcode 自动设置 SDK 信息。

## 弹出界面与控件

| 入口 | 官方组件与处理 |
| --- | --- |
| 推理等级 | SwiftUI `popover`；保留系统背景与圆角 |
| 顶部及输入栏模型选择、外观选择 | SwiftUI `Menu` / `Picker` |
| 历史筛选 | SwiftUI `popover`，其中使用原生 Switch |
| 对话长按操作 | SwiftUI `contextMenu` |
| 删除、清空、提示 | SwiftUI `confirmationDialog` / `alert` |
| 附件、设置、服务编辑 | SwiftUI `sheet`；iOS 26+ 移除不透明的内容背景，使用系统展示表面；设置 sheet 不再指定固定圆角 |
| 相机、相册、文件 | 系统相机、PhotosPicker、fileImporter，保留系统界面 |
| 推理等级滑条 | 官方 `Slider`，iOS 26+ 使用 `SliderTick` 步进初始化器 |
| Temperature 滑条 | 官方 `Slider` |
| 全部四处开关 | 官方 `Toggle` / `SwitchToggleStyle` |

没有为 popover 或 Slider 再叠加自绘玻璃层。根据 Apple 的说明，标准菜单、popover 与 sheet 会自动采用当前系统材质；Slider / Toggle 的滑块在交互时变为 Liquid Glass，静止外观由系统决定。系统版本、玻璃偏好、“降低透明度”和“减弱动态效果”也会影响显示。iOS 17–25 保留系统旧版控件和材质回退。

四组推理档位、附件导入、请求构造及开关保存行为沿用 1.3.0。

## 验证

42 项核心测试通过，完成 arm64 Release 编译。构建脚本会自动验证主程序的链接 SDK 为 26 或更新、匹配当前真实 Apple SDK、最低系统仍为 17，以及未启用旧设计兼容开关。还验证原生 Slider / Switch / Glass 链接与资源。此前 1.3.0 的真实二进制会被新的 SDK 验证规则拒绝。

本机没有可运行的 iOS Simulator 或连接的真机，尚未验收最终屏幕效果。签名安装后，请确认设置中的版本为 1.3.1 (5)，检查上述每个入口，并拖动 Slider、按住 Switch 检查系统交互材质。编译与符号检查不等同于视觉验收。

## 官方依据

- [Apple：Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)：使用最新 SDK 构建；标准控件自动采用；移除覆盖 sheet / popover 的自定义背景；Slider / Toggle 滑块在交互时变为 Liquid Glass。
- [Apple：Slider](https://developer.apple.com/documentation/swiftui/slider)
- [LLVM Mach-O linker](https://github.com/llvm/llvm-project/blob/main/lld/MachO/Driver.cpp)：`-platform_version` 指定平台、最低系统、SDK；同平台多项时以最后一项为准。
