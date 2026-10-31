# Faculae

**像 DeepSeek 一样简洁的 UI，自定义 API 与丰富功能兼得。**

Faculae 是一款原生 iOS AI 客户端，采用 SwiftUI 构建。在清晰的消息流、轻巧的输入栏和历史对话侧栏中，使用自己配置的 API，完成多模型对话、联网搜索和图像生成。

支持 iPhone / iPad、系统浅色与深色外观；iOS 26 及以上使用苹果原生 Liquid Glass 控件，较早系统使用系统材质。

**当前版本：2.3.4（36）** · **最低系统：iOS / iPadOS 17** · **许可证：[MIT](LICENSE)**

[版本说明](docs/UI-2.3.4.md) · [Windows 构建指南](docs/BUILD-WINDOWS-WSL.md) · [系统分享与签名](docs/SHARING.md) · [第三方许可](docs/THIRD-PARTY-NOTICES.md)

## 功能概览

| 功能 | 说明 |
| --- | --- |
| 简洁的原生界面 | Liquid Glass 按钮、菜单、开关和 Slider；跟手的对话侧栏、浅色 / 深色主题、iPhone / iPad 布局 |
| 自定义 API 与多模型 | 配置供应商地址、Key 与协议；每个供应商添加多个模型，分别设置 API 模型名、显示名、图标和参数；支持拖动排序 |
| 流式对话与推理 | 逐步接收回复，显示思考过程，调节推理等级；支持停止、重新生成、多轮上下文与切换会话继续生成 |
| 图像生成 | OpenAI / Gemini 文生图与参考图生成；可设置分辨率、比例、质量、格式、审核、透明背景或压缩率，实际支持取决于模型与接口 |
| 联网搜索 | DeepSeek 官方 Search / Fetch，以及 Tavily、Brave、Serper、SearXNG 和自定义 JSON 服务；回答末尾可查看网页来源 |
| 富文本回复 | 离线 Markdown、数学公式、代码高亮、表格与 Mermaid 图表；公式、字体和渲染脚本随应用提供 |
| 附件与系统分享 | 相机、相册、文件和其他 App 的系统分享入口；支持图片、PDF、文本 / 代码及常见办公文档文字提取 |
| 会话管理与导出 | 历史搜索、置顶、重命名、多选管理；从任意已完成回复分支到新会话；导出会话 MD、单条回答 TXT / MD 或整段对话图片 |
| 后台生成与状态 | 系统后台执行时间、持续后台任务、任务恢复机会、实时活动与本地通知；锁屏 / 灵动岛展示模型、状态、用时和 tokens |
| 用量与个性化 | tokens 统计、自定义余额查询接口、头像与用户名、竖屏锁定、字体大小、模型 Logo 和触觉反馈 |
| 本地保存 | API Key 存入 iOS Keychain；会话、附件和配置保存在本机，支持数据管理 |

## 支持的服务与接口

| 服务 / 协议 | 对话接口 | 图像生成 |
| --- | --- | --- |
| OpenAI 及兼容服务 | Chat Completions | Images Generations / Edits |
| DeepSeek | OpenAI 兼容对话接口 | 按实际服务提供的能力配置 |
| Google Gemini | 原生 GenerateContent | 原生 GenerateContent 生图 |
| Anthropic Claude | 原生 Messages | — |

供应商是连接配置，一个供应商可以包含多个模型。API 模型名用于请求，显示名用于界面；更改显示名不会改变实际调用的模型。模型类型可设为「对话模型」或「图像生成」，选择生图模型后输入栏自动显示对应的参数入口。

OpenAI 对话接入使用 Chat Completions。仅提供 Responses API 的服务目前需要另行适配。模型列表、识图、推理等级、生图参数和搜索能力由服务端决定；默认模型 ID 为可编辑示例，不代表账号已获得相应权限。

### API 地址示例

| 服务 | Base URL 示例 | 认证 |
| --- | --- | --- |
| OpenAI 兼容 | `https://api.openai.com/v1` | `Authorization: Bearer …` |
| DeepSeek | `https://api.deepseek.com` | `Authorization: Bearer …` |
| Gemini 原生 | `https://generativelanguage.googleapis.com/v1beta` | `x-goog-api-key` |
| Claude 原生 | `https://api.anthropic.com/v1` | `x-api-key` |

支持带路径前缀的 HTTPS 中转地址。选择与服务端一致的协议，再填写自己的地址、Key 和实际可用的模型 ID。联网搜索服务单独配置，搜索与模型请求可能分别计费。

## 开始使用

1. 使用自己的账号或证书为构建出的 IPA 签名安装，或按下方说明从源码构建。安装包包含主应用、实时活动扩展和分享扩展，需要一起签名。
2. 从历史对话侧栏进入「设置 → API 与模型」，添加或编辑供应商，填写协议、API 地址和 Key。
3. 在供应商内手动添加模型，或读取接口模型列表后多选添加。设置模型名称、显示名称、模型类型及需要的参数，保存模型后再保存供应商。
4. 回到聊天页，通过模型菜单选择供应商和模型，发送消息。对话模型可调节推理等级；生图模型通过「参数」按钮调整生成设置。
5. 需要联网时，在「API 与模型」页面的搜索提供商分类中添加服务，再从聊天页的联网搜索菜单选择并开启。
6. 在「后台生成」「个性化」「余额用量」「触觉反馈」中调整偏好；系统权限可在「设置 → 系统权限」中检查。「关于」分类还提供项目 GitHub 与 MIT 许可证的网页入口。

已有会话可继续使用，也可通过回复底部的分支按钮创建独立会话，保留该节点及此前的上下文。其他 App 分享文件到 Faculae 的签名与 App Group 要求见 [系统分享说明](docs/SHARING.md)。

## 从源码构建

### 环境要求

| 用途 | 环境 |
| --- | --- |
| 运行应用 | iOS / iPadOS 17 及以上；Liquid Glass 需要 iOS 26 及以上 |
| Mac 构建与模拟器 | Xcode 26.3 或更高版本；iOS 27 专用后台提交接口需要包含 iOS 27 SDK 的 Xcode |
| Windows 本地构建 | WSL2、Ubuntu 24.04 x86_64、Swift 6.4.1、xtool 1.24.0、Apple iOS SDK；资源目录使用固定版本 accord 编译 |
| 修改消息渲染器 | Node.js 与 npm；普通 App 构建使用仓库内已打包资源，无需安装 Node.js |

工程中的 `SeekAPI`、`SeekActivity`、`SeekShare` 名称是内部标识，应用对外名称为 Faculae。已有 Bundle ID、App Group、钥匙串和数据路径保留以兼容覆盖安装；使用自己的签名身份时应保持主应用与扩展配置一致。

### Mac / Xcode

```bash
git clone https://github.com/Fastwakend/Faculae.git
cd Faculae
open SeekAPI.xcodeproj
```

选择 **SeekAPI** Scheme 和 iPhone / iPad 模拟器运行。普通模拟器构建不需要开发者签名。

真机安装前，为主应用、`SeekActivity` 和 `SeekShare` 三个 target 选择自己的 Team。可复制 `Config/Signing.xcconfig.example` 为 `Config/Signing.xcconfig` 后填写；扩展 Bundle ID 分别使用主 ID 加 `.activity` 和 `.share`，主应用与分享扩展的 App Group 必须匹配。签名配置文件已在 Git 忽略列表中。

运行核心协议测试与模拟器构建：

```bash
bash scripts/verify_macos.sh
```

需要真机归档时，在 Xcode 中使用 **Product → Archive**，再以自己的签名导出 IPA。仓库附带 [GitHub Actions 工作流](.github/workflows/ios.yml)，显式选择 Xcode 26.3 运行 macOS 核心测试并编译 iOS 模拟器版本；其模拟器产物不能安装到真机。iOS 27 专用的后台提交接口在支持该 SDK 的编译器中启用，较早 SDK 使用兼容的系统接口。

### Windows / WSL2

可在本地交叉编译 arm64 iOS IPA。先按 [完整配置指南](docs/BUILD-WINDOWS-WSL.md) 安装 Swift、xtool、accord，并从 Apple 官方 Xcode XIP 提取 SDK。源码仓库不包含 Xcode、SDK、签名证书或构建缓存。

配置完成后，在 Ubuntu 终端进入项目目录运行：

```bash
bash scripts/build_wsl.sh
```

脚本运行测试、编译主应用及两个扩展、编译图标资源并打包。输出位于 `artifacts/Faculae-unsigned.ipa`，需签名后安装。Windows / WSL 无法运行 Apple 的 iOS Simulator。

仅运行核心测试：

```bash
bash scripts/build_wsl.sh test
```

## 数据、权限与能力边界

- **凭据与本地数据**：API Key 单独保存于 Keychain；会话、附件、配置、头像和模型图标保存在应用沙盒。Key 不写入聊天导出。应用不提供会话云同步。
- **请求去向**：聊天内容与所选附件发送至当前配置的模型服务；开启搜索时，搜索词发送给所选搜索服务，检索结果作为模型上下文。切换供应商后继续同一会话，会向新服务发送有效上下文。
- **附件处理**：每条消息最多 6 个附件，单文件最多 1 GiB，总计最多 6 GiB；供应商仍可能有更小的限制。办公文档提取文字最多 1 MiB，不执行宏；上传图片会缩至最长边 2048 像素并转换为 JPEG，生成图片保留生成尺寸与所选格式。
- **系统权限**：拍照、相册保存、通知、实时活动和实验性定位按所需功能申请权限；系统文件与照片选择器使用逐项授权。系统分享还需要有效的 App Group 签名权限。
- **后台运行**：持续后台任务、后台刷新、实时活动和更新频率由 iOS 调度。系统终止进程后的流式连接无法自动续接；已有内容会保存，可手动重新生成。实验性定位与静音音频默认关闭，仅在有生成任务时运行。

API 服务、搜索服务、额度和模型访问权限由用户自行配置，具体能力与费用以服务商为准。

## 验证状态

当前 **2.3.4（36）** 的已有本地构建记录：

| 检查 | 结果 |
| --- | --- |
| SeekCore 核心测试 | 129 项通过 |
| 系统分享导入测试 | 10 项通过 |
| 资源编译器 iOS 测试 | 12 项通过（编译器未变，沿用 2.3.3 记录） |
| Swift 语法、工程与资源引用 | 92 个 Swift 文件检查通过 |
| iOS arm64 Release | 主应用、实时活动扩展与分享扩展编译打包完成 |
| 发布资源与图标 | IPA 完整性、资源清单、SDK 与原生控件导入检查通过；浅色 / 深色 iPhone / iPad 图标解码像素与确认稿一致 |

这些结果来自 Windows / WSL 本地构建，详见 [本地验证记录](docs/local-validation.json)、[静态检查记录](docs/static-validation.json) 与 [发布校验记录](docs/build-wsl/release-checks.json)。真机安装、原生交互、系统后台行为及实际 API 请求仍需按设备和服务分别验收。未签名 IPA 和模拟器构建成功不能替代这些检查。

后续 CI 修复已在 GitHub 托管的 macOS / Xcode 26.3 环境验证：131 项核心测试通过，iOS 模拟器 App 与扩展构建成功，产物上传成功。详见 [CI 环境、失败原因与成功记录](docs/CI.md)。

## 项目结构

```text
SeekAPI/                主应用、界面、服务与资源
SeekActivity/           锁屏与灵动岛实时活动扩展
SeekShare/              系统分享扩展
SeekAPI.xcodeproj/      Xcode 工程
Packages/SeekCore/      协议、数据模型、请求解析与核心测试
Packages/SeekWebP/      WebP 编解码依赖及其许可
Config/                 构建、权限与签名配置模板
scripts/                Mac / WSL 构建与环境配置脚本
tools/                  项目生成、资源打包与验证工具
docs/                   功能说明、构建指南和验证记录
LICENSE                 项目 MIT 许可证
```

## 文档导航

- [2.3.4 版本说明](docs/UI-2.3.4.md)
- [Windows / WSL 本地构建](docs/BUILD-WINDOWS-WSL.md)
- [系统分享、签名与 App Group](docs/SHARING.md)
- [浅色 / 深色图标说明](docs/ICON-FACULA.md)
- [设备验收清单与历史版本记录](docs/DEVICE-TESTING.md)
- [第三方资源与许可](docs/THIRD-PARTY-NOTICES.md)

## 反馈与贡献

欢迎通过 [Issues](https://github.com/Fastwakend/Faculae/issues) 反馈问题或提出建议，也可以提交 Pull Request。复现问题时请说明应用版本、iOS 版本、接口协议和操作步骤；附带日志或截图前请移除 API Key、签名凭据和私人对话。

涉及协议或数据结构的修改，可先运行 `swift test --package-path Packages/SeekCore`，再按构建说明检查主应用与扩展。修改消息渲染器时，请保留依赖锁文件、完整许可和更新后的资源清单。

## 许可证与致谢

除另有声明的第三方内容外，本项目采用 [MIT 许可证](LICENSE)，允许使用、修改和分发，包括商业用途；分发时需保留 MIT 版权与许可文本。

现有第三方 Logo、依赖和字体继续遵循各自的许可证，不因本项目采用 MIT 而改变：

- [模型 Logo 许可](SeekAPI/Resources/ModelLogoLicenses.txt)：Lobe Icons / LobeHub，MIT。
- [渲染器与字体完整许可](SeekAPI/Resources/MarkdownRenderer/ThirdPartyNotices.txt)：marked、KaTeX、DOMPurify、Mermaid、highlight.js 及相关依赖的声明。
- [WebP 许可与专利授权](SeekAPI/Resources/WebPLicense.txt) 和 [libwebp COPYING](Packages/SeekWebP/COPYING)。

感谢上述项目，以及用于本地构建的 Swift、xtool 与 accord。供应商名称和 Logo 的商标权属于各自权利人，仅用于识别所选服务；MIT 许可不授予这些商标权，也不表示获得相关供应商背书。完整索引见 [第三方许可说明](docs/THIRD-PARTY-NOTICES.md)。
