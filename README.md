# Faculae · iOS AI 客户端

**Faculae** 是一款原生 iOS AI 客户端，拥有像 DeepSeek 客户端一样简洁、专注的 UI，同时支持自定义 API、多供应商多模型、联网搜索、图像生成和丰富的个性化设置。

采用 SwiftUI 构建，提供清晰的消息流、轻巧的输入栏和历史对话侧栏，支持系统浅色 / 深色外观，并在 iOS 26 及以上使用苹果原生 Liquid Glass 控件。适用于 **iOS / iPadOS 17 及以上**。

**已在 Windows + WSL2 本地编译出未签名 IPA：`artifacts/Faculae-unsigned.ipa`。** 安装到普通 iPhone 前需要用自己的账号或证书签名。仓库提供完整源码、构建脚本和文档，支持本地重复构建。

当前版本 **2.3.3（35）**：应用名称改为 Faculae；Windows / WSL 构建通过固定版本的 accord 将已确认的浅色、深色星芒图标编译为 `Assets.car`，合并原生主图标信息，支持 iPhone / iPad。详见 [本版说明](docs/UI-2.3.3.md)。保留 [分支与菜单图标](docs/UI-2.3.2.md)、[后台持续任务与实验性服务](docs/UI-2.3.0.md)、[列表排序与设置导航](docs/UI-2.2.0.md) 和 [生图参数](docs/UI-2.0.0.md)。安装包包含主应用及两个扩展，需一起签名。

用户确认的 Faculae 三颗星芒图标包含同一图标集中的浅色与深色外观，详见 [图标接入说明](docs/ICON-FACULA.md)。资源重建保留确认稿原图；WSL 构建在 xtool 装配后补上编译后的资源目录和主图标声明。桌面外观跟随 iOS 的桌面图标设置；安装后的外观切换仍需真机验收。

## 已实现的源码功能

- 每个供应商可添加多个模型，共用地址、Key 和协议；支持手动添加及读取接口列表后多选添加。默认提供 DeepSeek、OpenAI、Gemini、Claude 供应商。
- 供应商、模型和搜索提供商列表支持原生拖动排序，点分类标题右侧「排序」后拖动把手；供应商与搜索顺序直接保存，模型顺序随供应商草稿保存。聊天菜单使用相同数组顺序，重启后保留。
- 编辑页可删除供应商及其模型和 Key，列表支持长按 / 左滑入口；已有聊天保留，至少保留一个供应商。
- 聊天原生液态玻璃菜单先列出供应商，点开各自二级菜单选择模型；每个模型独立保存推理等级、系统提示词、最大输出及 Temperature，历史对话记住所用模型。
- 每个模型分别设置 API 模型名称和界面显示名称；聊天标签、菜单及列表显示自定义名字，留空则显示模型 ID。底部标签以模型对应的供应商 Logo 或自定义图标替代地球，原生菜单各项文字统一对齐。
- OpenAI Chat Completions 兼容协议、Google Gemini 原生协议、Anthropic Claude Messages 原生协议。
- OpenAI Images / Gemini GenerateContent 文生图及多参考图生成；有参考图时 OpenAI 使用 Images Edits，Gemini 使用 inlineData。模型独立保存类型与生图参数，原生玻璃「参数」按钮弹性展开居中面板；生成图大图预览、全屏缩放和相册保存，支持真实 PNG / JPEG / WebP 格式。
- 流式回答、停止生成、重新生成、复制；原生保存菜单可保存单条回答为 TXT / MD，或保存整段对话为图片到相册。显示 API 返回的思考内容。聊天复用单一滚动页面，只更新变化的消息，图表库按需加载。
- 输入区底部原生液态玻璃单行操作栏，推理按钮紧跟模型显示名称；推理滑条按模型系列提供档位：OpenAI / Claude 为 Low、Medium、High、Xhigh、Max；DeepSeek 为 Off、Low、High、Max；Gemini 为 Low、Medium、High。iOS 26+ 使用苹果原生步进 Slider 与液态玻璃滑块。
- 拍照、系统相册、最近照片和文件选择；支持图片、PDF、文本/代码，以及 DOCX、XLSX、PPTX、ODT/ODS/ODP、RTF、HTML 文字提取。已发送图片可点击全屏预览、缩放并保存到系统相册；DeepSeek Flash 不再被模型名前缀限制为纯文字。
- 搜索提供商独立配置，支持 DeepSeek 官方 Search / Fetch、Tavily、Brave、Serper、SearXNG 和自定义 JSON 接口。聊天地球菜单开关联网上下文；回复末尾的「X 个网页」为原生 Liquid Glass 按钮，点击打开原生来源面板，历史回复保留来源。
- 随模型切换的透明品牌标志，设置各级页面统一深色主文字与原生玻璃导航按钮。
- 每个模型可独立选择 OpenAI / DeepSeek / Claude / Gemini 内置 Logo，或从相册、文件导入自己的图片；支持预览、移除和恢复自动识别，图标不会作为聊天附件发送。
- 系统提示词、最大输出、可选 Temperature；模型列表读取与分页。
- 本地历史记录、搜索、重命名、置顶、删除；长按对话可通过系统文件保存器导出整个会话为 UTF-8 MD 文件。
- 任意已完成回复可「分支到新对话」，包含所选节点及之前的上下文、附件和模型元数据，原会话保留；新旧会话使用独立消息 ID。
- 全屏水平拖动跟手打开/关闭历史侧栏，非线性弹性吸附可中断；对话行不再支持左滑删除，保留多选置顶 / 取消置顶和确认后删除。
- 离线 Markdown 表格、嵌套列表、图片、代码高亮与复制，KaTeX 数学公式和 Mermaid 图表；iPhone / iPad 布局和系统深色模式。
- 参考图样式的留白首页、滑动历史抽屉和分组设置页；iOS 26+ 使用原生 Liquid Glass，iOS 17–25 使用系统材质。
- 设置支持跟随系统 / 浅色 / 深色、聊天字号、思考过程显示、自动跟随回答和对话数据管理。
- 「个性化」支持从相册设置头像、自定义用户名和竖屏锁定，保存后显示于对话列表下方，仅在本机使用。
- 「余额用量」统计本机请求的输入/输出 tokens，支持按供应商填写余额 API 与 JSON 字段路径、手动刷新和分钟自动刷新。
- 「后台生成」提供原生开关控制后台执行时间、系统恢复机会、ActivityKit 实时活动和本地任务通知；锁屏/灵动岛显示供应商 Logo、模型显示名、状态、计时和 tokens。系统终止进程后的 SSE 无法自动接回，保留检查点供手动重新生成。
- iOS 26+ 在前台发送时申请官方持续后台任务，显示请求/运行状态，按真实接收量更新进度；iOS 27 使用异步提交接口。实验性后台定位、静音音频默认关闭，仅有生成任务时运行，不保存或上传坐标。系统仍可能终止，不能保证无限后台时间。
- 默认开启「切换对话时继续生成」，支持多个会话独立接收回复；停止按钮只停止当前会话。实时活动设置提供无 API 调用的显示测试、状态与诊断记录，声明更频繁更新支持，实际展示与预算由 iOS 决定。
- 任务通知设置分别显示 App 开关、系统权限、通知横幅与锁屏显示状态，支持申请权限和跳转系统设置，回到前台后刷新。
- “关于 → 系统权限”显示相机、照片、保存图片、通知、实时活动、后台刷新与实验性定位状态，可点击申请或打开系统设置；文件使用逐个文件授权。
- 全应用开关统一为苹果官方 Switch；iOS 26+ 交互时呈现系统液态玻璃，旧系统使用原生外观。
- 「触觉反馈」提供全局、开关、侧边栏、列表项、思考卡片、消息生成六个原生开关与强度 Slider；设置保存在本机，流式反馈节流，仅前台播放。
- API Key 单独存入 iOS Keychain，配置文件和聊天导出不包含 Key。

## 在 Mac 上构建

当前源码需要含 iOS 27 SDK 的 Xcode 27 或更高版本；App 的最低运行系统仍为 iOS 17。Swift 依赖为仓库内的 `SeekCore` 与 `SeekWebP` Package，无需 CocoaPods 或 XcodeGen；离线消息渲染脚本与公式字体已包含，无需 Node 即可编译 App。

1. 将整个源码目录复制到 Mac，打开 `SeekAPI.xcodeproj`，选择 **SeekAPI** Scheme。
2. 先选择一个 iPhone 模拟器运行。模拟器构建不需要 Apple 开发者签名。
3. 真机安装时，在主应用、SeekActivity 和 SeekShare 三个 target 的 **Signing & Capabilities** 选择自己的 Team。通过 `SEEK_APP_BUNDLE_IDENTIFIER` 设置唯一主 ID，扩展使用相同 ID 加 `.activity` 后缀。也可复制 `Config/Signing.xcconfig.example` 为 `Config/Signing.xcconfig` 后填写；该本地文件已加入忽略列表。
4. 启动 App，点击底部模型标签 → **API 与模型设置** → **API 与模型**，进入供应商，填写自己的地址与 Key。也可从历史侧栏底部进入设置。
5. 在供应商的模型区点击 **手动添加模型**；或 **读取模型 / 测试连接** → **从列表添加**，搜索并多选模型。点开模型分别填写 **模型名称**（请求用的 API ID）和 **显示名称**（界面用的名字，可留空），并修改对话参数。左滑可移除，至少保留一个。返回供应商页面后点右上角勾号保存。
6. 返回聊天页，点击底部模型标签，先选择供应商，再进入二级菜单选择模型。部分中转服务不实现模型列表，可手动添加其支持的模型 ID。
7. 进入某个模型的「模型图标」，选择四家内置 Logo，或从相册、文件导入图片。保存模型后，再保存供应商；图标用于首页、设置列表和新回复头像，历史回复保留发送时的图标。
8. 需要联网时，在「API 与模型」的供应商列表下添加搜索提供商，填写接口类型、地址与对应 Key 并保存。聊天底部点击地球选择服务并开启；DeepSeek 输入网页链接可直接抓取正文。检索参考资料随请求发送给当前聊天模型，搜索与模型用量可能分别计费。

运行协议测试和模拟器编译：

```bash
bash scripts/verify_macos.sh
```

真机归档可在 Xcode 菜单选择 **Product → Archive**，再从 Organizer 使用自己的签名导出 IPA。

仓库附带 `.github/workflows/ios.yml`，推送到自己的 GitHub 仓库后可运行 macOS CI。CI 运行 XCTest 并构建未签名的模拟器 App；模拟器产物不能安装到真机。该工作流尚未在当前目录中远程执行。

## 在 Windows 上本地构建

支持 WSL2 + Ubuntu 24.04 + Swift 6.4.1 + xtool 1.24.0。从 Apple 的 Xcode XIP 提取 SDK 后，可在本机交叉编译 arm64 iOS IPA，无需 Mac 或云编译。

本机已配置完成后，在 PowerShell 中运行：

```powershell
wsl.exe -d Ubuntu-24.04 -- bash '/mnt/d/codex projects/ai前端/scripts/build_wsl.sh'
```

成功后产物为 `artifacts/Faculae-unsigned.ipa`，可使用 Windows 上的 Sideloadly 配合自己的 Apple 账号签名安装。构建阶段不需要 Apple 登录；WSL 无法运行 Apple 的 iOS Simulator。完整安装与重建说明见 [Windows 本地编译](docs/BUILD-WINDOWS-WSL.md)。

## API 地址怎么填

| 协议 | Base URL 示例 | 生成请求 | Key 位置 |
| --- | --- | --- | --- |
| OpenAI 兼容 | `https://api.openai.com/v1` | `/chat/completions` | `Authorization: Bearer …` |
| DeepSeek（OpenAI 兼容） | `https://api.deepseek.com` | `/chat/completions` | `Authorization: Bearer …` |
| Gemini 原生 | `https://generativelanguage.googleapis.com/v1beta` | `/models/{model}:streamGenerateContent?alt=sse` | `x-goog-api-key` |
| Claude 原生 | `https://api.anthropic.com/v1` | `/messages` | `x-api-key`，附 `anthropic-version: 2023-06-01` |

支持 HTTPS 中转地址及路径前缀，例如 `https://gateway.example/anthropic/v1`。按中转服务实际提供的协议选择类型。OpenAI / Claude 支持粘贴完整生成接口地址，程序会去掉重复后缀。

默认模型 ID 是可编辑的示例，并不代表你的账号有对应模型权限。读取列表或手动使用服务商给出的 ID。OpenAI 接入范围为 Chat Completions；仅实现 Responses API 的服务需要另加适配。

消息渲染器支持 `$…$`、`$$…$$`、`\(…\)`、`\[…\]` 数学定界符，以及 mermaid 围栏图表。依赖脚本与字体随 App 提供；Markdown 图片可通过 HTTPS 加载，点击链接通过系统浏览器打开，渲染器不会加载远程脚本。相关许可见资源目录和 [第三方来源](docs/THIRD-PARTY-NOTICES.md)。

## 数据与网络

Key 通过对应的请求头发送到你指定的 HTTPS 服务，不写入 URL。搜索 Key 使用独立钥匙串命名空间；联网开启时，本次搜索词发送给搜索服务，检索资料发送给当前聊天模型，附件与整段聊天历史不发送给搜索服务。网络会话不保留 Cookie / URL 缓存，且拒绝 HTTP 重定向。系统 TLS 校验保持启用。

API Key 使用 `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 存入钥匙串。附件单独存放于 `Application Support/SeekAPI/Attachments/`，聊天 JSON 只保存附件元数据；每条消息最多 6 个附件，单个原文件最多 1 GiB，请求总量最多 6 GiB，供应商上下文及请求体限制仍然适用。文本文件从磁盘分块发送，办公文档提取文字最多 1 MiB，不执行宏或保留完整排版。上传图片自动缩至 2048 像素并转换为 JPEG，去除原始定位元数据；生成图片保留原始尺寸，按所选格式保存。Markdown 导出包含消息文字与附件名称，不包含附件原文件。相机权限用于拍照；只有主动点“显示最近照片”才请求 PhotoKit 读取权限，主动保存图片才申请仅添加权限，系统相册选择无需允许整个图库。

对话和配置存放于沙盒 `Application Support/SeekAPI/state.json`，采用原子写入和 iOS 文件保护，并排除系统云备份。聊天内容会作为上下文发送给当前选择的 API 服务；服务商的保留策略由该服务决定。切换服务后继续同一对话，会向新服务发送这条对话的有效上下文。

旧版单模型配置会自动迁入每个供应商的模型列表，保留地址、供应商 UUID 和原模型的全部参数，钥匙串继续使用原供应商 UUID，无需重新输入 Key。保存格式为 v3，同时支持读取 v1/v2；旧聊天可根据最后一条助手回复恢复模型，新聊天直接记录模型 UUID。

自定义模型图标与用户头像存放于 `Application Support/SeekAPI/ModelIcons/`，配置和回复只保存 UUID 引用。图片在本机缩小至最长边 256 像素的 PNG，保留透明度并移除原始元数据，导入源文件最多 20 MB。图标和头像不加入 API 请求或 Markdown 导出；启动时清理未被模型、历史回复、当前用户头像引用的图片，取消编辑产生的未使用图片也会清理。

开启后台生成后，切到后台会使用 iOS 分配的时间继续接收，时间耗尽时停止并保存已有内容；关闭该选项则离开前台时停止。切换对话是否继续由独立开关控制。断流会显示错误并保留已收到的文本。Key 无效、模型不可用、配额不足及安全拦截会显示错误，可修改配置后重新生成。

## 验证状态

当前版本为 **2.2.0 (31)**。本版运行 121 项核心测试与 10 项分享文件测试，均通过，主 App 与两个扩展完成 iOS arm64 Release 编译打包。未变更渲染器与 WebP 源码，沿用 2.1.0 的 34 项桌面渲染结果与 2.0.0 的 2 项 Linux 编解码结果。设置点按、拖动排序与原生界面尚待 iPhone 验证；详见 [2.2.0 变更与验证边界](docs/UI-2.2.0.md)。

当前主机为 Windows，已在 WSL2 Ubuntu 24.04 中安装 Swift 6.4.1 并执行 121 个核心 XCTest，用例全部通过，包含列表排序、多模型、生图参数与响应、参考图请求、分支、触觉设置、配置迁移、会话任务隔离、办公文档提取、搜索请求/解析、1GB 文件边界和磁盘请求编码。既有 8 组富文本与 26 组对话/导出桌面结果不替代 iPhone 帧率、系统分享、原生文件保存或相册长图验收。另已检查 Swift 语法树、Xcode 项目语法与文件引用、Source Build Phase、plist、Scheme 和图标资源。

使用所提供 Xcode 27.2 RC 中的 iOS SDK，已完成整个 SwiftUI App 的 arm64 Release 交叉编译及 IPA 打包。IPA ZIP 校验通过，主程序为 arm64 Mach-O，最低系统版本为 iOS 17.0，包含图标与隐私清单。记录见 [docs/local-validation.json](docs/local-validation.json)。

**尚未执行真机安装、界面、Keychain、历史保存和三个服务商的真实联网验收，也未完成 Apple 开发者签名。** 本地编译成功不能替代这些设备验证。

## 目录

```text
SeekAPI.xcodeproj/        可直接打开的 Xcode 工程
SeekAPI/App/             App 入口与聊天任务状态
SeekAPI/Views/           聊天、Markdown、历史和 API 设置
SeekAPI/Services/        流式网络、Keychain、本地保存
Packages/SeekCore/       请求构造、响应解码、SSE 解析及 XCTest
Packages/SeekWebP/       libwebp 编码器、解码器及许可证
Config/                  构建与可选本地签名配置
scripts/verify_macos.sh  macOS 测试与模拟器构建
scripts/build_wsl.sh     Windows / WSL 本地测试与 IPA 构建
tools/                   项目生成、构建与发布验证工具
docs/                    功能说明、构建指南和验证记录
```
