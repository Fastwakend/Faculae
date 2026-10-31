# 1.2.0 (3)：设置、推理、模型标志和附件

## 界面变化

所有设置子页（API 列表、API 编辑、字号、个性化、数据与隐私）使用 `SettingsScaffold`。标题居中、黑色主文字、浅灰页面与白色内容组，返回、取消和保存使用原生玻璃按钮；深色外观使用系统对应文字色，保持可读性。一级页的数据管理使用 iOS 17 已提供的 `externaldrive` 图标。

欢迎区按模型名称显示 DeepSeek、OpenAI、Gemini 或 Claude 的透明 Logo；模型名称优先于协议，因此 OpenAI 兼容协议的 Claude 服务也显示 Claude 标志。其他自定义模型显示通用星芒。xtool 包从 `Bundle.main` 根目录显式读取 PNG，Xcode 构建回退到 asset catalog。图标来源与 MIT 许可见 [第三方声明](THIRD-PARTY-NOTICES.md)。

输入区的服务标签右侧增加推理按钮，点开弹出原生滑条。加号打开附件面板，上方为最近照片，下方为“拍照 / 相册 / 文件”。首次未授权图库时显示“显示最近照片”入口；用户也可直接用系统相册选择器，无需开放整个图库。附件在输入框预览，可移除；支持不输入文字直接发送附件。

## 推理参数

| 协议 / 模型 | 非自动档请求参数 |
| --- | --- |
| OpenAI 兼容的 o3、o4、GPT-5、GPT-6，以及 Claude / Gemini 中转 | `reasoning_effort: low / medium / high` |
| Gemini 2.5 原生 | `generationConfig.thinkingConfig.thinkingBudget` |
| Gemini 3 原生 | `generationConfig.thinkingConfig.thinkingLevel`；Pro 中档映射为 high |
| Claude 3.7、4.x 的手动思考模型 | `thinking.type: enabled` 和 `budget_tokens` |
| Claude 4.6+ 与 5.x 的自适应模型 | `thinking.type: adaptive` 和 `output_config.effort` |
| DeepSeek chat / reasoner | 在弹层内切换深度思考模型，不发送不支持的等级字段 |

自动档不发送推理覆盖参数；未知或不支持的模型保留按钮和说明，禁用滑条。兼容中转是否接受 `reasoning_effort` 取决于具体网关，自动档可恢复原请求。Claude 开启推理时不发送 Temperature。

预算档受最大输出约束：低最多 1024，中最多 4096（并取最大输出的一半），高最多 8192（并小于最大输出）。默认 4096 输出时，分别为 1024 / 2048 / 4095。最大输出不超过 1024 时，预算调节返回明确错误。

## 附件与保存

- 图片通过 ImageIO 缩至最长边 2048，转换成 JPEG，移除原始 EXIF 信息；相机与系统相册、最近照片均接入同一导入流程。
- 文件支持图片、PDF 以及 UTF-8 文本（包括 Markdown、JSON、CSV 和代码）；未知二进制文件返回说明。每条最多 6 个，单个最多 8 MB，文本最多 1 MB，一次请求包括历史附件最多 20 MB。
- OpenAI 图片使用 `image_url` 数据 URI，PDF 使用 `file` 内容块；Gemini 使用 `inlineData`；Claude 使用 `image` / `document` 和 base64 source。文本附件作为文字内容块发送。
- 附件二进制单独保存在本机受保护、排除备份的目录中，JSON 只保存元数据。删除对话成功保存后清理其附件；启动时清理未发送的遗留文件。Markdown 导出仅包含附件名称。
- DeepSeek 文字模型不发送图片或 PDF，保留草稿并提示切换模型。其他模型的视觉 / PDF 支持仍由实际模型和网关决定，服务错误会正常显示。
- 新字段为 optional，旧版配置与聊天无需重置即可读取；API Key 的存储方式不变。

## 验证

32 项核心 XCTest 覆盖原有请求与流解析，并加入旧数据解码、推理参数、预算边界、附件序列化、无文字附件、相邻用户消息附件合并、文件缺失与大小限制。使用 WSL2 中的 Swift 6.4.1 / xtool 1.24.0 和 iPhoneOS 27.2 SDK 实际编译 arm64 Release 包。

当前主机无法运行 iOS Simulator；尚未在设备上验收视觉、相机、相册、文件选择、持久化或真实服务请求。最终构建、资源及校验记录见 [local-validation.json](local-validation.json)。

## 官方协议依据

- [Apple：Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views)
- [OpenAI：Chat Completions create](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)
- [OpenAI：File inputs（Chat Completions 仅 PDF，文字文件应转文字内容块）](https://developers.openai.com/api/docs/guides/pdf-files)
- [Google：ThinkingConfig REST schema](https://ai.google.dev/api/generate-content#ThinkingConfig)
- [Anthropic：Extended thinking](https://platform.claude.com/docs/en/build-with-claude/extended-thinking)
- [Anthropic：Adaptive thinking](https://platform.claude.com/docs/en/build-with-claude/adaptive-thinking)
- [Anthropic：Vision](https://platform.claude.com/docs/en/build-with-claude/vision)
- [Anthropic：PDF support](https://platform.claude.com/docs/en/build-with-claude/pdf-support)
