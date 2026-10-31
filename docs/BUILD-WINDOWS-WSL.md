# Windows 本地编译 iOS IPA

这套工程可通过 WSL2 内的 Swift 与 xtool 交叉编译，生成 arm64 iPhone / iPad 使用的 IPA。构建不需要 Mac，也不需要提交 Apple 账号。安装到普通 iPhone 前仍需签名；Windows 上不能运行 Apple 的 iOS Simulator。

## 本机路径

- Ubuntu：`Ubuntu-24.04`（WSL2），磁盘位于 `D:\linux\Ubuntu-24.04`。
- 源码：`D:\codex projects\ai前端`。
- 用户提供的 Xcode：`D:\codex projects\ai前端\Xcode_27.2_Release_Candidate.xip`。
- Swift：6.4.1；xtool：1.24.0；accord：固定提交 `98e463c15609b13c26ec8a2971c2248e7e1d544d`。
- 编译副本与缓存：WSL 的 `~/.cache/seekapi-build/workspace`。
- 构建脚本成功后输出：`artifacts/Faculae-unsigned.ipa`，同时保留 `SeekAPI-unsigned.ipa` 兼容旧脚本。

本机已完成 Faculae 2.3.3 (35) Release 交叉编译，129 个核心测试、10 项分享导入测试与 12 项资源编译器 iOS 测试全部通过。主应用和两个扩展均已更新名称，IPA 包含 iPhone / iPad 浅色、深色主图标；解码后的图标像素与确认稿完全一致。详见 [本版说明](UI-2.3.3.md) 与 `local-validation.json`。尚未签名或运行真机；渲染器和 WebP 未改动，沿用已记录结果。

WSL 的 Linux 文件系统实际保存在 D 盘的发行版磁盘中。脚本不会把完整 Xcode、Swift 工具链或编译缓存解压到 C 盘。

## 已配置机器再次构建

在项目目录的 PowerShell 中执行：

```powershell
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/build_wsl.sh'
```

首次编译 2.3.3 或更新版本前，先执行 `wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/install_accord_wsl.sh'`。脚本在 WSL 内安装固定版本 Rust 与 accord，并校验下载内容。

构建脚本同步 `SeekAPI`、`SeekActivity`、`SeekShare`、`Packages`、`Config` 和 SwiftPM / xtool 配置到 Linux 目录，先运行核心测试，再编译主应用、资源目录和两个扩展并嵌入 IPA，最后复制产物回 Windows。不要在同一编译目录同时运行多个构建。

从 1.3.1 起，请通过此脚本构建 iOS App。它从已安装 SDK 的 `SDKSettings.json` 读取真实版本，设置 `SEEK_IOS_SDK_VERSION` 并让 manifest 明确传入链接器；避免把最低系统 17.0 误当成链接 SDK，使原生菜单和 Slider 沿用旧外观。构建末尾会执行 `verify_release.py` 检查真实 Mach-O 元数据，记录见 `artifacts/ios-sdk-build.json` 和 `docs/build-wsl/release-checks.json`。如果 SDK 安装在其他目录，可将 `SEEK_IOS_SDK_SETTINGS` 设置为对应 `SDKSettings.json` 的完整路径。Mac / Xcode 不使用这组 Linux 链接参数。

只运行协议层测试：

```powershell
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/build_wsl.sh' test
```

## 新机器配置

先安装 Ubuntu 24.04 x86_64 的 WSL2 发行版，然后运行依赖脚本：

```powershell
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/bootstrap_wsl_dependencies.sh'
```

在 Ubuntu 终端中安装 Swiftly 与 Swift：

```bash
mkdir -p ~/.cache/seekapi-downloads/swiftly
cd ~/.cache/seekapi-downloads/swiftly
curl -fL --retry 3 https://download.swift.org/swiftly/linux/swiftly-x86_64.tar.gz -o swiftly.tar.gz
tar xzf swiftly.tar.gz
./swiftly init --skip-install --assume-yes --quiet-shell-followup
. ~/.local/share/swiftly/env.sh
swiftly install 6.4.1 --use --assume-yes
```

Swiftly 默认验证 Swift 工具链的 PGP 签名。安装 xtool 的脚本固定版本并验证 SHA-256，通过解压 AppImage 避免依赖 FUSE：

```powershell
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/install_xtool.sh'
```

从 [Apple 开发者下载页](https://developer.apple.com/download/all/?q=Xcode) 获取 Xcode XIP。SDK 安装会读取其中的 SDK 与 Swift 接口，不会在 Linux 上运行 Xcode。

本机 WSL 使用 xtool 直接下载配套依赖时出现连接超时，可先在 PowerShell 下载官方宏与链接工具包。脚本对两份固定版本归档校验 SHA-256，随后 SDK 安装脚本将它们复制进 Linux 缓存：

```powershell
& './scripts/download_xtool_sdk_dependencies.ps1'
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/install_ios_sdk_wsl.sh' '/mnt/d/codex projects/ai前端/Xcode_27.2_Release_Candidate.xip'
```

使用 `--slim` 提取以节约空间。升级 xtool 并要求新版 SDK 时，需要从 XIP 重新安装，不能原地更新 slim SDK。

## 签名与真机验收

生成的 `Faculae-unsigned.ipa` 用于后续签名，不能直接点击安装到普通 iPhone。可在 Windows 使用 Sideloadly，选择该 IPA、连接自己的 iPhone，并在签名工具内登录自己的 Apple 账号完成安装。不要把 Apple 密码写入源码或聊天。

首次安装可能需要在 iPhone 开启开发者模式，并在“设置 → 通用 → VPN 与设备管理”中信任对应开发者。免费 Apple 账号签名通常需要定期续签，具体限制以 Apple 和签名工具当时的规则为准。

安装后按 [设备验收步骤](DEVICE-TESTING.md) 检查界面、钥匙串、历史保存与真实 API。编译成功和协议层测试通过，不代表这些设备行为已经验证。

## 配置与证据

`Package.swift` 把同一套 SwiftUI 源码导出为库，xtool 将其 `@main` 入口链接成 App；`xtool.yml` 提供 Bundle ID、图标与资源。`Config/Info-xtool.plist` 使用具体版本号，避免依赖 Xcode 的构建变量替换。原来的 Xcode 工程仍可用于 Mac 构建和调试。

Faculae 确认版的浅色 / 深色图标均在同一个 `AppIcon.appiconset`，母图保存在 `tools/artwork/facula/`。运行 `python tools/create_assets.py` 可原样重建。2.3.3 起，`build_assets_wsl.sh` 使用固定提交的 accord 编译资源目录，`embed_assets.py` 把 `Assets.car`、兼容 PNG 和主图标元数据合并进 xtool 生成的 IPA，替换只注册单张 PNG 的旧方案。详见 [图标说明](ICON-FACULA.md) 和 [2.3.3 说明](UI-2.3.3.md)。

核心测试日志：`artifacts/core-tests-wsl.log`；SDK 提取日志：`artifacts/sdk-install-wsl.log`；iOS 编译日志：`artifacts/ios-build-wsl.log`。当前实际验证状态记录在 [local-validation.json](local-validation.json)。源码 ZIP 不包含 Xcode XIP、IPA、签名凭据或构建缓存。

官方工具：[xtool 1.24.0](https://github.com/xtool-org/xtool/releases/tag/1.24.0)、[Linux 安装说明](https://github.com/xtool-org/xtool/blob/1.24.0/Documentation/xtool.docc/Installation-Linux.md)、[Swift Linux 安装](https://www.swift.org/install/linux/)。


## 1.7 验收补充

见 [1.7 聊天与富文本](UI-1.7.md)：检查标题渐变模糊、两个顶部图标、白字灰边模型按钮、长模型名滚动与固定推理/附件/发送位置。检查推理按钮原生玻璃变形展开、点击外部收起、所有档位拖动时位置稳定、旋转与大字号，以及减少动态效果。

断网打开已有消息，检查表格、四种定界符公式、希腊字母、Mermaid、代码复制、浅/深色及流式补全；宽表格与代码只能横向滚动，正文高度变化应自动跟随。桌面渲染回归不能替代 iPhone 上 WebKit 和 VoiceOver 验收。普通构建使用已打包脚本和字体；仅修改渲染器时才需按 1.7 文档运行 npm 重建资源。


## 1.8 交互与滚动更新

最新实现与验收步骤见 [1.8 交互与滚动](UI-1.8.md)。1.7 的玻璃形变自绘浮层已替换为独立系统 Popover，避免与输入框融合；不再用全屏锚点层。两个选择按钮使用原生玻璃按钮，并在同一横向行中依次排列。

聊天只复用一个网页和原生滚动视图，移除逐条网页高度反馈链。普通聊天不加载图表库。顶部使用 iOS 26 的公开 UIScrollEdgeEffect.soft 和 UIScrollEdgeElementContainerInteraction；内容可以绘制到状态栏背景，控件仍避开 top safe area。旧系统保留系统材质回退。

桌面已覆盖 120 条历史消息滚动和 40 次增量输出；仍需安装 1.8 IPA 在真机检查标题按钮点击、Popover 分离、键盘 / 旋转 / 灵动岛 / 横向表格手势和滚动帧率。

## 1.9 玻璃展开与底部延伸

最新行为见 [1.9 界面与管理](UI-1.9.md)。推理面板改为专属容器内的原生玻璃变形，并与整个输入框保持间隔；仅展开时存在遮罩。聊天画布扩展到底部，消息经过输入框后方；侧栏搜索下移，供应商编辑页增加删除入口，左滑删除按钮恢复系统样式。上述 1.8 节记录当时实现，推理弹层和底部布局以 1.9 为准。原生动画、键盘、Home 指示条和删除持久化仍需真机验收。

## 1.10 推理回归与交互侧栏

最新实现以 [1.10 交互与回归修复](UI-1.10.md) 为准。修复输入框覆盖推理按钮锚点，缩小选择按钮；全屏水平拖动直接控制侧栏，线性吸附可中断。历史列表增加多选置顶和删除，移除筛选菜单，搜索栏与聊天顶部按钮对齐；顶部取消强烈 interactive 玻璃高光，设置页使用明确的系统分组背景。65 个核心测试和 16 组桌面渲染检查通过；原生触控、动画、手势竞争、安全区和实际配色仍需设备验收。

## 系统分享扩展

本版 WSL 脚本还会构建并嵌入 `SeekShare.appex`，分享扩展与主 App 通过 App Group 交接文件。主应用与两个扩展必须一起签名，且主应用和分享扩展需要相同的有效 App Group 权限。详见 [签名和分享操作](SHARING.md)。单纯将权限模板放入 IPA 不会授予系统权限。
