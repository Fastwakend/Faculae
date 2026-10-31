# DeepSeek IPA 静态分析

输入：`DeepSeek-ipaomtk.com.ipa`。分析以 ZIP、plist、Mach-O Load Commands 和可见字符串为依据，没有执行包内二进制、网页脚本或附带说明。原包保持不变。

| 项目 | 观察结果 |
| --- | --- |
| SHA-256 | `f27dee20b1cbc4ff2d2d956afcb75861161e424efb4599b48e719ba5d555baf3` |
| ZIP 大小 | 17,895,510 bytes |
| 清单条目 | 675 |
| Bundle ID | `com.deepseek.chat` |
| 版本 | `1.7.7`，build `2` |
| 主程序 | `Payload/DeepSeek Chat.app/DeepSeek Chat` |
| 架构 | arm64，64 位 Mach-O |
| 主程序加密标记 | `LC_ENCRYPTION_INFO_64`，`cryptid = 0` |
| 原包 SDK | `iphoneos26.0` |
| 原包声明最低系统 | iOS 10.0；此声明未通过真机验证 |
| 新工程最低系统 | iOS / iPadOS 17.0 |

`cryptid=0` 表示主程序的对应区段没有声明 FairPlay 加密；不等于获得 Swift 源码、原开发者签名或 App Store 分发资格。包内保留 `SC_Info` 元数据，但未发现 `.swift` 源文件。

## 可观察的结构

主程序依赖 UIKit、SwiftUI、WebKit；第三方框架包括 Alamofire、SnapKit、FlexLayout、MMKV、WCDBSwift、Highlightr、DSLatex、iosMath 等。类型名中可见 `RootViewController`、`InputViewModel`、`MessageListView`、`UserMessageView`、`ThinkFragmentView`、`SessionManager` 和 `NetworkManager`。

这支持“原生界面为主、部分富文本使用网页渲染”的判断。`MermaidViewer` / `MermaidGenerator` 及语法高亮资源不能代表整个 App 是可直接修改的 HTML 前端。这里没有反汇编每个函数，也未恢复原始 Swift 控制流；结论限于上述静态证据。

## 协议证据

二进制字符串包含以下路径及头名称：

```text
/api/v0/chat/completion
/api/v0/chat/create_pow_challenge
/api/v0/chat/history_messages
/api/v0/chat/regenerate
/api/v0/chat/stop_stream
/api/v0/chat_session/create
/api/v0/chat_session/fetch_page
/api/v0/users/login
X-DS-PoW-Response
X-DS-Guest-PoW-Response
x-ds-sse-heartbeat-timeout-secs
```

字符串中可见 `chat.deepseek.com`、`cdn.deepseek.com` 等域名；完整清单位于 JSON。字符串出现仅证明相关值存在于包中，不能证明实际发起了请求，也不能单凭这些值判断网络行为。

专用会话接口、认证与 PoW 流程跟 OpenAI Chat Completions、Gemini GenerateContent、Claude Messages 的请求体和响应事件不同。因此当前实现选择在独立源码中重建聊天流程及三个协议适配，而不是对原 Mach-O 做字符串替换。

## 交互与实现映射

| 原 App 中可观察的功能线索 | 新工程 |
| --- | --- |
| 消息列表、用户消息、助手消息 | `ChatView`、`MessageRow` |
| 输入区域、新对话、停止、重新生成 | `ChatView`、`AppStore` |
| 思考片段 | `ResponseDecoder` 分离 reasoning 与 text，`MessageRow` 折叠显示 |
| 历史会话、标题 | 本地 `Conversation`、`HistoryView` |
| Markdown / 代码资源 | 原生基础 Markdown、代码块与复制 |
| 原 DeepSeek 专用网络层 | 独立 `RequestBuilder`、`SSEParser`、`ResponseDecoder`、`AIStreamingClient` |
| 服务商配置 | 新增 `ProfilesView`、`ProfileEditor` 与系统 Keychain |

界面风格以白底、蓝色、留白和侧栏为方向。没有运行原 App 或截取原 App 屏幕，所以当前实现不声称是逐像素还原。原品牌图标、框架及网页资源均未复制到新 App。

## 复现

使用 Python 标准库即可重新生成分析报告：

```bash
python3 tools/inspect_ipa.py DeepSeek-ipaomtk.com.ipa
```

输出：[ipa-analysis.json](ipa-analysis.json)、[ipa-inventory.txt](ipa-inventory.txt)。脚本仅从 ZIP 读取数据，不执行或释放包内可执行文件。
