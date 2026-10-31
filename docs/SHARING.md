# 从其他 App 分享文件

1. 在“文件”、相册或其他支持系统分享的 App 中选择文件，点“分享”。
2. 在 App 一栏选择 **Seek API**；首次可能需要在“更多”中启用。
3. 读完文件后点“保存到 Seek API”，再点“完成”。若显示“通过系统‘文件’导入”，点“选择文件夹并保存”，选择 **我的 iPhone → Seek API → 导入附件**；首次请先打开一次主 App 创建该目录。
4. 返回 Seek API，确认文件列表，点“添加到对话”。附件会进入当前草稿；检查后点发送。

使用公开 Share Extension 接口，不通过扩展强行启动主 App。主 App 关闭时，已确认保存的文件保留在 App Group 待导入区，下一次启动或回到前台会读取。取消导入会保留分享批次，下次回到前台可重试；成功添加后删除该批次。不会自动调用模型或扣除 API 额度。

每次最多 6 个文件，单个最多 1 GB，总计最多 6 GB（按 1024 进制）。文件复制、JSON 编码和上传使用磁盘分块处理。分享入口支持文件、图片、网页链接和文字；链接按文本导入，不会擅自抓取网页。聊天附件的实际识别能力与 App 内的文件入口一致：图片、PDF、办公文档、RTF、网页及文本/代码。办公文档的正文提取保护上限保留，供应商另有请求/上下文限制；不支持的内容会明确报错，原分享批次保留。文件提供方读取超时后显示错误，建议先在原 App 下载到本机。

## 签名配置

安装包现在含有两个扩展：`SeekActivity.appex`（实时活动）和 `SeekShare.appex`（系统分享）。主 App、两个扩展必须一起签名安装，不能删除扩展目录。

分享扩展直接交接文件需要有效的 **App Groups** 权限；系统“文件”中转无需这项权限：

| 对象 | Bundle ID | App Group |
| --- | --- | --- |
| 主应用 | `app.seekapi.ios` | `group.app.seekapi.ios` |
| 分享扩展 | `app.seekapi.ios.share` | `group.app.seekapi.ios` |
| 实时活动扩展 | `app.seekapi.ios.activity` | 无需 App Group |

在 Apple 开发者账户中为自己的主应用与分享扩展注册并启用同一个 App Group，重新生成包含该权限的描述文件，再签名。更换 Bundle ID 时，也需要将 App Group 改为账户内可用的标识，并同步修改 `ShareInbox.groupID` 和两个 entitlements 文件。

Xcode 工程已为主应用和分享扩展配置 `CODE_SIGN_ENTITLEMENTS`：

- `Config/SeekAPI.entitlements`
- `Config/SeekShare.entitlements`

WSL 产物仍是未签名 IPA。包内 `ShareAppGroup.entitlements` 和分享扩展的 `Signing.entitlements` 是给签名工具的权限模板；把 XML 文件放进安装包本身不会授予权限。直接导入必须由签名工具把权限写入签名，且与有效描述文件一致。1.16.0 起，爱思或其他重签工具移除 App Group 权限时，扩展自动改用系统“文件”保存流程。

## 无 App Group 权限时的入口

在 Seek API 分享页选择“选择文件夹并保存”，将文件保存到“我的 iPhone → Seek API → 导入附件”，再返回主 App 确认添加。主应用只会消费这一目录内已确认导入的文件。若保存到其他位置，可在聊天附件菜单选择“文件”手动添加。该流程是用户授权的系统文件复制，不能省略保存目录选择而静默跨越沙盒。

主 App 也注册了文件打开接口。在支持该操作的 App/“文件”中选择 **“用 Seek API 打开”或“拷贝到 Seek API”**，可直接进入导入确认，无需跨扩展共享空间；该入口是否出现由文件提供方和系统决定。

## 真机验收

- 主 App 关闭时，从“文件”分享本地 PDF/文本/办公文档，再启动 App 确认导入和发送。
- 从相册分享图片，确认草稿缩略图、发送、预览及保存。
- 从 iCloud/第三方文件提供方分享，分别检查已下载、未下载、取消、超时和无法读取的文件。
- 检查同名文件、多文件、6 个上限、单文件 1 GB 和合计 6 GB 限制。
- 检查取消导入后可重试、失败时不丢原批次，以及成功添加后不会重复导入。
- 在不含 App Group 的重签包中检查“文件”中转、保存取消、保存到正确/其他目录；验证直接“用 Seek API 打开”的备用入口。

本地已完成源码编译和文件队列测试，未执行开发者签名、分享菜单注册或真机跨进程交接。

官方接口参考：[Share extensions](https://developer.apple.com/documentation/foundation/app-extension-support)、[App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)、[NSItemProvider](https://developer.apple.com/documentation/foundation/nsitemprovider)、[UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)。
