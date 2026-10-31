# Seek API 2.0.0（28）

本版加入 OpenAI 与 Gemini 文生图，保留对话模型、搜索、附件和原有会话功能。旧模型默认继续作为「对话模型」，旧聊天与 API Key 无需重新配置。

## 使用入口

1. 在「设置 → API 与模型 → 编辑供应商 → 模型设置」将模型类型设为「图像生成」，填写该服务支持的生图模型 ID。模型的显示名与图标仍可独立设置。
2. 保存模型和供应商，在聊天底部选择这个模型。输入区隐藏推理等级及联网搜索，模型选择右侧显示「参数」。
3. 点击「参数」，原生液态玻璃面板从按钮弹性展开到屏幕中间。填写参数与文字提示词后发送。
4. 回复以大图显示，点击图片可全屏缩放并保存到相册。历史记录保留图片及发送时的参数。停止、切换会话继续生成、后台时间与实时活动沿用已有设置。

本版实现文生图，不包含参考图编辑。生图模式下附件入口禁用；如草稿中已有附件，会提示先移除后发送。

## 参数

| 分类 | 可选值 | 处理方式 |
| --- | --- | --- |
| 基础分辨率 | 1K、2K、4K | OpenAI 转为实际像素尺寸；Gemini 使用 `imageSize` |
| 图像比例 | 1:1、3:2、2:3、16:9、9:16、4:3、3:4、21:9、自定义 | 预设配比例矩形图标；自定义接受正数宽高，例如 `16:9` |
| 质量 | Auto、Low、Medium、High | OpenAI 原生 `quality`；Gemini 作为提示词偏好 |
| 格式 | PNG、JPEG、WebP | OpenAI 原生 `output_format`；Gemini 返回图片后在本机编码 |
| 审核 | Auto、Low | OpenAI 原生 `moderation`；Gemini Low 使用四类 `BLOCK_ONLY_HIGH` 安全阈值 |
| PNG 透明背景 | True、False | OpenAI 原生 `background`；Gemini 作为提示词偏好，False 时本机合成白底 |
| JPEG / WebP 压缩率 | 留空或 0–100 整数 | 0 表示不额外压缩、100 表示最大压缩；JPEG 格式本身仍是有损编码 |

每个模型独立保存参数。发送前检查无效比例、压缩率及协议支持情况，不会静默忽略不支持的比例。Gemini 接口仅接受其支持的比例，任意自定义比例可能被拒绝；等价于支持比例的输入（如 `32:18`）会规范化。OpenAI 目前限制长宽比在 1:3 至 3:1，像素边长按 16 对齐。

OpenAI 的 1K / 2K / 4K 在本版分别使用约 1,048,576 / 4,194,304 / 8,294,400 的像素预算，并限制最长边 3840。面板显示实际发送的宽高；4K 方图约为 2880 × 2880，16:9 为 3840 × 2160，不会发送超限的 4096 × 4096。不同模型或中转平台支持的尺寸、质量和格式仍以该接口为准。

OpenAI 的 `output_compression` 按编码质量处理，填写的压缩率转换为 `100 - 压缩率`；留空则省略此字段，使用接口默认值。Gemini 原生接口没有与 OpenAI 完全对应的质量和透明背景控制，这两项通过提示词请求，不能保证模型执行；格式和压缩在本机处理。PNG 保留实际返回的透明通道，无法凭本机转码为不透明图片自动抠图。

## 接口和图片存储

- OpenAI 使用 `/images/generations`，兼容 base64 图片和 HTTPS 图片地址。图片地址以新的 GET 下载，不携带供应商 API Key，拒绝重定向。
- Gemini 使用 `models/{model}:generateContent`，发送 `responseModalities: ["TEXT", "IMAGE"]` 与 `imageConfig`，解析图片、文字说明和返回的 tokens 用量。
- 图像回复沿用附件存储，但保留生成图的原始尺寸，不套用普通上传照片的 2048px 缩图限制。预览和整段图片导出分别使用适合展示的缩略图。
- 引入 BSD 许可的 libwebp 1.6.0 实现真实 WebP 编码，许可证及专利授权随源码和 App 附带。保存 WebP 到系统相册时转换成 PNG 副本，原始 WebP 保留在 App 中。
- 生图响应 JSON 上限 192 MB、单张源图上限 128 MiB、最多 6 张，解码像素上限 4000 万。失败、停止和过期任务清理未使用图片。历史中的生成图不会自动作为下一次普通聊天的输入附件发送。
- Claude 原生协议没有对应生图入口；OpenAI 兼容中转应选择 OpenAI 协议，并使用该平台实际支持的模型。

## 本地验证

- Windows + WSL2、Swift 6.4.1、xtool 1.24.0、iOS SDK 27.2：主 App 与两个扩展完成 iOS arm64 Release 编译。
- 106 项核心 XCTest 通过，包含旧数据兼容、模型类型和参数持久化、OpenAI / Gemini 请求、尺寸及比例、压缩端点、响应解析、安全错误、会话恢复和生成图上下文隔离。
- 10 项分享导入测试通过；31 项桌面富文本 / 对话检查通过，包含生成图片的大图展示、点击图片身份传递及整段图片导出准备。
- libwebp 实际编译 119 个 C 源文件，2 项编解码测试通过：无损逐像素往返，以及质量 0 / 25 / 50 / 75 / 100 的编码解码、尺寸和不透明通道检查。
- Swift 语法、Xcode 工程引用、资源、IPA ZIP CRC、版本、arm64、原生玻璃符号、WebP 编码符号与许可证检查通过。主 App 无编译 warning；扩展保留交叉链接器关于 iOS 支持的提示，详见日志。

尚未使用真实 OpenAI / Gemini Key 请求图片，尚未进行 iPhone 上的原生液态玻璃交互、图片预览保存、后台生图及帧率验收。桌面检查不能替代这些验证。交付 IPA 未签名，安装时须将主 App、实时活动扩展及分享扩展一起签名。

## 官方依据

- [OpenAI 图像生成指南](https://developers.openai.com/api/docs/guides/image-generation)
- [OpenAI Images Generate API](https://developers.openai.com/api/reference/resources/images/methods/generate?lang=curl)
- [Gemini GenerateContent / ImageConfig](https://ai.google.dev/api/generate-content#ImageConfig)
- [Gemini 图像生成指南](https://ai.google.dev/gemini-api/docs/image-generation)
- [libwebp 源码归档](https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz)
