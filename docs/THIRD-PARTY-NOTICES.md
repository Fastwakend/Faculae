# 模型图标来源

透明 PNG 来自 [Lobe Icons](https://github.com/lobehub/lobe-icons) 的 `@lobehub/icons-static-png` 2.5.0 包：`dark/openai.png`、`dark/claude.png`、`dark/gemini-color.png`、`dark/deepseek-color.png`。OpenAI 和 Claude 在应用中作为模板渲染；Gemini 与 DeepSeek 保留原色。商标属于各自权利人，仅用来标识当前所选模型。

完整许可同时随 IPA 的 `ModelLogoLicenses.txt` 分发。

```text
MIT License

Copyright (c) 2023 LobeHub

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```


## 离线消息渲染

使用 marked 18.1.2、KaTeX 0.19.1、DOMPurify 3.4.17、Mermaid 12.2.0、highlight.js 11.12.0 及其生产依赖。版本与完整依赖树由 tools/markdown-renderer/package-lock.json 锁定。构建工具从实际安装包收集许可，并将完整 ThirdPartyNotices.txt 与全部字体一起放入 SeekAPI/Resources/MarkdownRenderer/，随源码与 IPA 分发。资源 manifest 包含每个文件的校验值。
