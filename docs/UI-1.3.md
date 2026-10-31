# 1.3.0 (4)：底部操作行、推理档位与全应用原生开关

## 布局

输入框保留文本区域，下方只有一行：模型服务选择、推理等级、添加附件、发送 / 停止。移除原来会把选择器放在上一行的 `ViewThatFits` 分支，消除选择器下方的空白。标准 iPhone 宽度显示完整操作行；窄屏、较大动态字体或过长的服务名称下，左侧两项在同一行横向滚动，加号和发送保持可见。

## 档位

| 模型系列 | 滑条档位 |
| --- | --- |
| OpenAI | Low、Medium、High、Xhigh、Max |
| DeepSeek | Off、Low、High、Max |
| Claude | Low、Medium、High、Xhigh、Max |
| Gemini | Low、Medium、High |

系列按实际模型 ID 识别，优先于配置的 API 协议和服务显示名称，因此 OpenAI 兼容协议的 Claude / Gemini / DeepSeek 仍有各自正确的档位。生成过程中暂时禁止修改；其他时候四组滑条都可操作。

滑条使用 SwiftUI 官方 `Slider`。iOS 26+ 使用苹果新提供的步进刻度 `SliderTick` 初始化器，系统在拖动时为滑块呈现 Liquid Glass，并处理辅助功能和减弱透明度。没有自绘滑块、替换轨道或套用第三方玻璃控件。iOS 17–25 使用系统旧版 `Slider` 回退。输入区域和浮动控件继续使用原生 `glassEffect` / `GlassEffectContainer`。

## 全应用开关

“显示思考过程”“自动跟随回答”“发送 Temperature 参数”“只看置顶”四处统一通过 `SeekSwitch` 使用 SwiftUI 官方 `Toggle` 和 `.toggleStyle(.switch)`，保持系统绿色开启状态，文字继续随系统黑白模式显示。没有自绘开关、滑块覆盖层或第三方玻璃皮肤；iOS 26+ 的开关在交互时由系统呈现 Liquid Glass，iOS 17–25 自动使用对应系统的原生外观。偏好保存、筛选绑定及生成期间的禁用规则保持原有行为。

历史筛选改用系统 popover 展示真实 Switch，避免 `Menu` 将开关自动变成勾选菜单项。弹层仍保留“新建对话”，打开筛选时收起搜索键盘，选择新建后关闭弹层。

## 请求行为

- OpenAI 兼容：以原值发送 `reasoning_effort`，包括 `xhigh`、`max`。旧模型可能不接受这些参数，服务错误会明确显示，不将高档位偷偷降为 high。
- DeepSeek Chat Completions：Off 转为 `reasoning_effort: none`、`thinking.type: disabled`；其他档位转为 `low` / `high` / `max` 和 `thinking.type: enabled`。思考开启时不发送 Temperature。DeepSeek 的 Anthropic 兼容接口使用 `reasoning.effort` 与 `output_config.effort`。
- Claude 原生：支持自适应思考的 4.6+、5.x 模型使用 `thinking: adaptive` 和原值 `output_config.effort`。手动思考的旧模型使用五档不同的 token 预算，在 1024 到 `min(32768, max_tokens - 1)` 间按档位分配；默认 4096 最大输出对应 1024 / 1791 / 2559 / 3327 / 4095。这里不增加用户的最大输出上限。
- Gemini 原生：Gemini 2.x 使用三档 token 预算；Gemini 3+ 按 REST 枚举传递 `thinkingLevel: LOW / MEDIUM / HIGH`。不再将 Pro 的 Medium 偷换成 High；具体版本不支持 Medium 时由服务报错。
- 自定义中转能否接收这些字段、某个具体版本能否接受最高档，取决于该服务和模型。客户端保留用户选定的模型 ID，不为设置推理而偷偷改成另一个模型。完整 DeepSeek 档位需要支持该参数的模型，例如官方当前文档使用的 `deepseek-flash` 或 `deepseek-v4-pro`；旧别名的支持需向中转确认。

旧版 `automatic` 与缺省值仍可解码。为了不在升级时意外改变已有请求，它们在操作行显示“推理”；首次打开新滑条时才采用明确档位（DeepSeek 旧 reasoner 为 High，其他 DeepSeek 为 Off，其他系列为 Low）。滑条中没有 Automatic 档。已有明确的 Low / Medium / High 值保留；切换到档位集合较少的模型时映射到该系列可用档并在界面显示。

## 验证

42 项核心 XCTest：原有聊天、附件、流解析及数据兼容测试继续通过；新增四组精确档位、模型系列识别、DeepSeek 四档请求、OpenAI / Claude Xhigh 与 Max、Claude 旧版五档预算、Gemini 三档不合并，以及新旧存档往返测试。

已实际完成 Windows / WSL arm64 Release 编译打包。`verify_release.py` 检查原生 Glass 符号和新增的 iOS 26 SliderTick / Slider 初始化器均为 weak import，保证旧系统可回退；同时确认安装包链接了苹果原生 `SwitchToggleStyle`。符号检查只能证明原生控件已编译链接，不能替代屏幕效果验收。当前没有 iOS 真机或模拟器可用于视觉验收，也未使用用户 API Key 发起计费请求。记录见 [local-validation.json](local-validation.json)。

## 官方依据

- [Apple：Adopting Liquid Glass（标准 Slider / Toggle 的滑块在交互时变为 Liquid Glass）](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple：SwitchToggleStyle](https://developer.apple.com/documentation/swiftui/switchtogglestyle)
- [Apple：Slider](https://developer.apple.com/documentation/swiftui/slider)
- [Apple：SliderTick](https://developer.apple.com/documentation/swiftui/slidertick)
- [OpenAI：Reasoning models](https://developers.openai.com/api/docs/guides/reasoning)
- [DeepSeek：Create Chat Completion](https://api-docs.deepseek.com/api/create-chat-completion)
- [DeepSeek：Thinking mode](https://api-docs.deepseek.com/guides/thinking_mode)
- [Anthropic：Effort](https://platform.claude.com/docs/en/build-with-claude/effort)
- [Google：ThinkingConfig](https://ai.google.dev/api/generate-content#ThinkingConfig)
