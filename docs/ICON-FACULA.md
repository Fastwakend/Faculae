# 已采用的 Faculae 图标：三颗端正星芒

用户已确认 v4 图标并授权接入源码，随后选定应用名称为 Faculae。采用原星芒风格，三颗星芒均不旋转，原右下角的小圆点改成小星芒。

- 浅色：蓝色渐变底，珠光白星芒。
- 深色：深蓝渐变底，柔和发亮的浅色星芒。
- 两张图均为 1024 × 1024、不透明 RGB、嵌入 sRGB ICC；不预切圆角，由 iOS 应用图标蒙版。
- 直接使用用户确认的 PNG，逐字节复制，未重新绘制或调整配色、尺寸、位置、材质。

## 源码接入

`SeekAPI/Resources/Assets.xcassets/AppIcon.appiconset/` 包含：

- `AppIcon.png`：默认 / 浅色图标。
- `AppIcon-Dark.png`：深色图标。
- `Contents.json`：同一图标集中的默认外观与 `luminosity=dark` 外观声明。

Xcode 项目已有 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 设置，资源目录已在 Resource Build Phase 中，无需新建图标切换逻辑。

## 可重复生成

确定版母图与 SHA-256 记录在 `tools/artwork/facula/`，属于源码分发包的一部分，不依赖 `artifacts/` 或旧预览目录。运行：

```powershell
python tools/create_assets.py
```

会校验母图的哈希、PNG 头、1024px 尺寸及 RGB8 格式，然后将确认稿原样复制到 AppIcon 图标集，同时保留现有强调色。仅使用 Python 标准库。

也可以运行 `python tools/create_facula_icons.py --install` 只更新图标；不带 `--install` 则导出到 `artifacts/Faculae-Icons-approved/AppIcon.appiconset/`。此前 C 字母方案的生成脚本已归档到 v1 预览目录，不再由工程生成脚本使用。

## 构建边界与验证

2.3.3 (35) 将 Faculae 名称与两种外观一起编译进新版 IPA。原有版本化 IPA 与源码包保留。

原生桌面图标外观由 iOS 的桌面图标设置管理，独立于应用内主题。Xcode 可直接编译这套 asset catalog。Windows / WSL 流程现在使用固定提交的 [accord](https://github.com/MiloLug/dine-accord/tree/98e463c15609b13c26ec8a2971c2248e7e1d544d) 编译 `Assets.car`，包含 iPhone / iPad 的默认和 `UIAppearanceDark` 图标记录，并合并 `CFBundleIcons` / `CFBundleIcons~ipad` 主图标元数据。详见 [2.3.3 说明](UI-2.3.3.md)。这解决了此前 xtool 仅处理单张 PNG 的资源缺口；安装后的显示效果尚未真机验证。

已验证两张 PNG 与用户选定 v4 的 SHA-256 一致、尺寸 / RGB / ICC 正确、重建前后完全相同、资源配置含两种外观、Xcode 项目引用与静态检查通过。源码包包含确定版母图与生成脚本。
