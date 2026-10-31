# 第三方资源与许可

Faculae 项目采用 [MIT 许可证](../LICENSE)。第三方 Logo、依赖、字体和其他另有声明的内容继续适用各自的许可证与版权声明，不因项目采用 MIT 而改变。

| 内容 | 许可与完整声明 |
| --- | --- |
| Lobe Icons 模型 Logo | MIT；完整文本见下文和 [ModelLogoLicenses.txt](../SeekAPI/Resources/ModelLogoLicenses.txt) |
| Markdown、公式、代码高亮、图表及字体依赖 | 各依赖的许可证与版权声明见 [ThirdPartyNotices.txt](../SeekAPI/Resources/MarkdownRenderer/ThirdPartyNotices.txt) |
| libwebp 1.6.0 | BSD 3-Clause；见 [COPYING](../Packages/SeekWebP/COPYING)，随应用分发的 [WebPLicense.txt](../SeekAPI/Resources/WebPLicense.txt) 同时保留附带的专利授权文本 |

分发源码或应用时，应继续保留相应的版权、许可及附带声明。供应商名称和 Logo 的商标权属于各自权利人，项目的 MIT 许可证不授予相关商标权，也不表示获得供应商背书。

## 模型图标来源

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
