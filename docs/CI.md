# GitHub Actions 验证

工作流：[iOS build and protocol tests](https://github.com/Fastwakend/Faculae/actions/workflows/ios.yml)。运行命令为 `bash scripts/verify_macos.sh`。

## 执行环境与结果

- 使用 GitHub 托管的 `macos-15` 运行器，显式选择 `/Applications/Xcode_26.3.app/Contents/Developer`，避免默认 Xcode 16.4 缺少 Liquid Glass SDK。
- 先运行 SeekCore 的 macOS 测试，再解析包依赖并编译未签名的 iOS Simulator App。主应用会同时构建实时活动和分享扩展。
- 成功后上传 `SeekAPI-iOS-Simulator` 构建产物；模拟器 App 不能作为真机 IPA 安装。
- [2026-10-31 成功记录](https://github.com/Fastwakend/Faculae/actions/runs/41171926852)：代码提交 `d690c346fb5955b71e0ce6e654ac87e2defab135`，131 项核心测试通过，`BUILD SUCCEEDED`，模拟器产物上传成功。

## 早期失败原因

[早期失败记录](https://github.com/Fastwakend/Faculae/actions/runs/41166476105)停在 `RequestBuilderTests.testRejectsInvalidKeysModelsAndParameters`，尚未执行 App 编译。

API Key 校验使用字符串 `contains` 分别查找回车和换行。CRLF 可以组成一个扩展字形簇，该匹配在 macOS 与 Linux 的 Swift / Foundation 实现中表现不同，导致 macOS 没有拒绝含嵌入式 CRLF 的 Key。现改为检查 Unicode 标量中的 CR 和 LF，并保留复制 Key 时清理首尾空白的行为。回归用例覆盖 OpenAI、Gemini、Claude 的对话和模型列表请求。

工作流同时修正了 SDK 选择。iOS 27 新增的后台任务提交接口使用编译器条件和运行时版本检查；较早 SDK 使用兼容的系统提交接口，从而可以在 Xcode 26.3 编译，又保留使用 iOS 27 SDK 构建时的新版接口。

历史失败记录和已发送的邮件会保留；后续提交的状态应以对应的新运行结果为准。CI 结果不替代真机 UI、系统后台行为或实际 API 服务验收。
