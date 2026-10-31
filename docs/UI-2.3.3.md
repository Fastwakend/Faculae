# Faculae 2.3.3 (35)

应用、系统分享入口、实时活动扩展以及权限引导和导出文件名统一使用 Faculae。保留已有 Bundle ID、App Group、钥匙串、后台任务和深链接标识以及数据目录，使相同签名身份下的覆盖安装继续使用原有数据。

采用用户确认的三颗端正星芒图标，默认浅色为蓝色底，深色为深蓝色底。两张 1024px 母图及其 SHA-256 不变。iPhone / iPad 的两种外观编译到同一份 `Assets.car`，通过 `CFBundleIcons` 和 `CFBundleIcons~ipad` 注册为主图标，供系统按桌面图标外观选择。

## Windows / WSL 构建

xtool 1.24.0 原来只复制默认 PNG。现在由固定提交的 [accord](https://github.com/MiloLug/dine-accord/tree/98e463c15609b13c26ec8a2971c2248e7e1d544d) 编译 `.xcassets`，随后 `tools/embed_assets.py` 将 `Assets.car`、兼容 PNG 和编译器生成的主图标元数据合并进 IPA。资源编译器仅在构建时使用，不嵌入应用可执行文件。

新机器先运行 `scripts/install_accord_wsl.sh`。脚本校验下载归档的 SHA-256，以锁定依赖的 Cargo.lock 和 Rust 1.92.0 构建固定提交；工具、依赖和缓存均保存在 WSL 的 Linux 文件系统中。已有机器继续运行 `scripts/build_wsl.sh`。

产物为 `artifacts/Faculae-2.3.3-unsigned.ipa`；通用输出为 `Faculae-unsigned.ipa`，兼容脚本仍保留 `SeekAPI-unsigned.ipa`。IPA 包含主应用、实时活动扩展和分享扩展，需要一起签名。

## 验证与设备验收

构建检查主应用与扩展名称 / 版本一致、arm64 Mach-O 和 iOS SDK 27.2 元数据、资源完整性、原生控件导入、两种外观各自的 iPhone / iPad 图标记录和主图标注册，并对编译后的图片进行解码核对。

尚未连接真机。签名安装后，检查桌面名称 Faculae，在桌面「编辑 → 自定义」中依次选择浅色、深色和自动，确认星芒图标外观；系统的桌面图标设置与应用内主题独立。应用内原有对话、供应商和模型应继续保留。
