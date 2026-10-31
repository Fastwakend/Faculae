# 1.11 侧栏交互、余额用量与后台回复

版本：1.11.0（16）。主应用和 WidgetKit 扩展均使用实际 Apple iOS 27.2 SDK 编译，最低 iOS 17；原生 Liquid Glass 需要 iOS 26 以上。

## 交互修正

- 侧栏直接跟随水平拖动，松手后使用阻尼 0.86 的非线性弹性收尾。再次拖动先取得 presentation layer 当前位移，可中断、反向。尊重系统“减弱动态效果”。
- 移除历史对话行的全部 swipeActions，解除列表区域对父侧栏手势的屏蔽；在列表行上左滑可连续返回聊天。删除仍可通过长按菜单或多选后的确认框完成。
- “回到底部”的显式请求会取消 UIScrollView 惯性，再设置底部位置；自动跟随仍尊重用户正在拖动和减速的状态。
- 顶部按钮继续使用原生玻璃背景，增加最高 14% 的白色按压光及 0.96 缩放，释放后 0.12 秒淡出。图标始终保留，不降低到不可见。
- API 供应商整行提供完整矩形点击区域，包括中间留白。API 页只保留供应商卡片及添加入口，移除顶部宣传和底部说明卡片。

## 余额用量

入口：设置 → 服务 → 余额用量。每次回复完成或中断时更新本机请求记录；后台接收期间每两秒保存进度，前台每十秒保存。记录以回复 UUID 更新，检查点不会重复累计。重新生成属于新的实际请求，独立计数。删除聊天不删除用量记录。

OpenAI/DeepSeek 请求带 `stream_options.include_usage`，接收 finish_reason 后继续读取末尾 usage 和 [DONE]。Claude 合并 message_start 和 message_delta 的累计计数；输入包含普通输入、缓存读取和缓存写入。Gemini 记录 prompt、candidate、thoughts 和 total。缓存/推理明细属于总量子集，不再重复相加。没有最终统计的中断回复保留已报告计数，并单列未报告输出的估算。

统计范围是升级后本机发出的请求，不代表服务商账户全局消耗或精确费用。未返回 usage 的接口按收到文本的 UTF-8 字节数 / 4 估算输出，标注“≈”；没有可靠的输入估算。实时活动在最终用量到达后使用接口报告值。

每个供应商可独立设置：

- GET 余额 API 路径。支持 `/user/balance` 或当前供应商同一 HTTPS 域名、端口的完整 URL，沿用供应商协议的 Key 认证；拒绝重定向。相对路径 `balance` 接在 API 根路径之后，`/balance` 从域名根路径开始。
- JSON 字段路径。例如 `data.balance`、`$.data.balance`、`balance_infos[0].total_balance`，也支持 JSON Pointer `/data/balance`。字段须为数值或简短字符串。
- 显示单位，例如 USD、CNY。
- 自动刷新间隔 0–1440 整数分钟；0 表示仅手动刷新。自动查询在 App 前台进行，返回 App 后补查已到期的供应商。查询失败保留上次成功的余额，并显示错误及上次更新时间。

例如响应 `{"data":{"balance":12.5}}`，JSON 路径填 `data.balance`。DeepSeek 常见响应的对应路径为 `balance_infos[0].total_balance`；具体以用户所用接口为准。跨域余额接口不会携带另一个域名的供应商 Key。

## 后台生成

入口：设置 → 应用 → 后台生成。四项均为原生 Toggle / SwitchToggleStyle，iOS 26 使用系统液态玻璃开关。

1. 后台生成：默认开启。进入后台不再直接取消网络任务，使用 `UIApplication.beginBackgroundTask` 继续当前流；时间到期保存部分内容、停止任务、结束实时活动并按偏好通知。
2. 后台任务恢复：默认关闭。注册并按需提交 `BGAppRefreshTaskRequest` / `BGProcessingTaskRequest`，处理系统给予的检查、保存及清理机会。处理中同样有到期处理。
3. 实时活动：默认关闭。从开启后的下一条回复生效。
4. 任务通知：默认关闭。开启时申请系统通知权限。离开前台后的回复完成、失败或后台时间结束会安排本地通知；点击可打开相应对话。

后台时间长短及刷新/处理的执行时机由 iOS 决定，不能保证长回复一直在后台运行。系统结束进程后，通用 SSE 接口没有可恢复的服务端任务 ID，不能重新接入原流；本版保留最后检查点并标记中断，由用户手动重新生成，避免自动重复计费。强制结束进程时 iOS 不保证给予回调，也不能保证此时立刻发送本地通知。实时活动不提供额外后台执行权限。

配置包含 `fetch` / `processing` 后台模式，以及白名单 `app.seekapi.ios.reply.refresh`、`app.seekapi.ios.reply.processing`；没有使用音频等无关后台模式。

## 原生实时活动

`SeekActivity.appex` 是独立 WidgetKit 扩展，通过 ActivityKit 展示，不是 App 内绘制的灵动岛。与主应用共享 `ReplyActivityAttributes.swift` 的类型定义。活动中不包含 Key、API 地址或回复正文。

- 灵动岛紧凑形态：左侧供应商品牌 Logo，右侧系统自动计时。
- 展开形态：左上 Logo + 模型的自定义显示名，右上时间，下方左侧状态、右侧本条回复 tokens。
- 锁屏横幅：左侧 Logo，中间模型名及生成状态，右侧上下排列时间和 tokens。结束时停止计时并显示结束状态；长时间没有更新会显示连接状态待确认。
- 使用四个打包的透明供应商 Logo；指定内置品牌图标时跟随所选品牌，自定义图片回退为该模型所属品牌。系统使用 `Text(timerInterval:)` 计时，无需每秒唤醒 App。
- 状态为“正在接收回复”“正在后台回复”及完成/中断状态。ActivityKit 状态更新最多每秒一次，终态强制刷新；系统仍可自行限制更新频率。
- 点击活动通过 `seekapi://conversation/<UUID>` 返回对应对话，并关闭侧栏/设置。

主 App `app.seekapi.ios`，扩展 `app.seekapi.ios.activity`。安装时必须一起签名并保留扩展。Mac 工程包含扩展 target、共享源码、四个 Logo 和 Embed App Extensions 阶段。自定义签名可在 `Config/Signing.xcconfig` 中设置 `SEEK_APP_BUNDLE_IDENTIFIER` 和 Team，两个 target 使用对应主 ID 及 `.activity` 后缀。

## 本地验证及边界

- 73 项 SeekCore XCTest：包含累计 usage 合并、缓存/推理子集、usage-only 事件、异常计数、JSON 路径、余额接口同源限制、旧消息兼容及中断估算等。
- 16 项桌面 Chromium 渲染与长对话回归通过；滚动未替换消息 DOM 或重新加载资源。
- 49 个 Swift 文件语法解析；Xcode 主 target 28 个源码、扩展 target 2 个源码（共享属性文件同时加入两者），校验独立 Sources 和嵌入阶段。
- 两个 arm64 Release 可执行文件均已编译链接；检查 IPA CRC、扩展标识/版本、最低 iOS 17、实际 SDK 27.2、WidgetKit/ActivityKit/BackgroundTasks/UserNotifications 链接及 Logo 资源。
- WSL 的 LLD 在扩展链接时输出平台支持警告：`This version of lld does not support linking for platform iOS. Proceed at your own risk.` 链接返回成功，产物平台/SDK 元数据及框架链接检查通过；此警告保留在 `artifacts/activity-build-wsl.log`，不能据此宣称已完成真机可运行验证。

当前没有 Mac、iOS 模拟器或连接的 iPhone，也没有真实服务凭证。本版没有实测原生手势/按压、余额认证查询、后台时间到期、权限弹窗、灵动岛、锁屏刷新或签名安装。源码与编译校验不能代替这些运行时检查。

安装后建议检查：中央拖动侧栏并反向/中断、列表内左滑不出现删除、快速滚动时回到底部、API 行留白点击、配置余额接口及分钟刷新、四个开关保存、开始生成后锁屏/切后台、前后台状态和计时/tokens、完成/超时通知及活动点击返回。iOS 低电量、后台刷新关闭、网络中断和强制结束进程应分别验证。
