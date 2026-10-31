# 1.7 聊天工具栏与富文本

- 顶部历史按钮采用长短两条横线；右侧只保留圆形气泡加号的新对话按钮。标题背后加入系统材质，并用渐变遮罩向下淡出。
- 底部模型标签按显示名称自然增长；超长标签在左侧区域横向滚动。文字为白色，背景为半透明深灰，外沿灰色。内置 OpenAI 模板 Logo 在此处使用白色，用户导入图片保留原色。
- 推理按钮移到附件加号左侧，不参与模型标签滚动，增加同款灰色外沿。按钮文字仍只显示大脑图标和当前档位。
- iOS 26+ 通过同一 GlassEffectContainer 内共享 glassEffectID 和 matchedGeometry，实现按钮与推理面板之间的原生玻璃形变。按钮占位、所有档位文字宽度、面板宽度及底部锚点保持稳定。点击外部或 VoiceOver 退出操作收起；减少动态效果时关闭动画。iOS 17–25 保留系统材质回退。
- 推理滑条仍为苹果 Slider，iOS 26+ 使用系统步进刻度和 Liquid Glass 滑块。
- 助手正文与思考内容使用离线 WKWebView 排版：GFM 表格、嵌套列表、引用、任务清单、链接、图片、代码高亮与复制；KaTeX 数学公式；Mermaid 图表。宽表格、代码与长公式支持横向滚动。
- 模型文本以结构化参数交给页面，原始 HTML 转义，输出经过 DOMPurify。KaTeX 禁用 trust，Mermaid 采用 strict 模式，CSP 禁止网络脚本与连接，导航仅允许用户点击正常链接后由系统打开。渲染进程使用临时网站数据；脚本、样式、公式字体和第三方许可均随 App 打包。
- 流式更新合并渲染，完成时立即刷新；异步图表结果按修订号丢弃过期输出。高度改变继续支持聊天自动跟随。页面异常时回退为可复制纯文本。

构建使用现有 Windows + WSL2 工具链。桌面 Chromium 回归检查验证离线渲染；iPhone / iPad 上的玻璃动画、手势、WebKit 字体与无障碍仍须设备验收，不能用桌面浏览器替代。

## 重建离线资源

普通 Swift / Xcode / WSL 构建直接使用已生成资源，无需 Node 或下载 CDN。

修改渲染器后，在项目目录执行：

```powershell
npm ci --prefix tools/markdown-renderer --ignore-scripts --no-audit --no-fund
npm run build --prefix tools/markdown-renderer
npm test --prefix tools/markdown-renderer
```

生成文件位于 `SeekAPI/Resources/MarkdownRenderer/`，包含逐文件 SHA256 清单；IPA 校验程序核对实际资源与源码字节完全一致。第三方版本在 package-lock 和资源 manifest 中锁定；许可在资源 ThirdPartyNotices.txt 中。
