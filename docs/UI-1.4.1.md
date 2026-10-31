# 1.4.1 (9)：供应商二级菜单与精简推理按钮

聊天页顶部入口与输入框底部模型标签改为共用的原生二级菜单：

- 一级只列供应商名称，预置 DeepSeek、OpenAI、Gemini、Claude 各一行，底部保留设置入口。
- 点击供应商，打开只含其模型的二级菜单。当前供应商和当前模型均有勾选标记。
- 添加的自定义供应商也有各自的二级菜单，模型数量不再撑长一级菜单。
- 选择模型仍调用原有 `AppStore.selectModel`，生成期间禁用供应商子菜单及模型操作。

实现将 `ChatView.profileActions` 中直接展开的 `Section` 改为嵌套 `Menu`，由 iOS 管理子菜单导航、返回、定位和关闭。iOS 26+ 两层菜单均使用系统 Liquid Glass；更早系统保留原生菜单。没有覆盖系统菜单背景，也没有增加自绘弹层。

输入框的推理按钮只显示大脑图标与当前档位，例如大脑图标加 `High`，移除“推理 ·”前缀。尚未指定等级时显示“自动”，保持原有 API 默认行为；打开弹窗后沿用原有档位初始化。标题仍预留全部可用档位及“自动”的最大宽度，保留稳定 popover 锚点，滑动时不会因标题长短改变按钮宽度。辅助功能继续朗读“调整推理等级”和当前值。

供应商与模型的数据格式、独立参数和历史模型恢复逻辑沿用 1.4.0，推理弹窗和官方 Slider 保持原有功能。

验证：执行工程静态检查、52 项核心 XCTest、arm64 Release 编译和 IPA 的 SDK / 原生控件链接检查，实际记录见 [local-validation.json](local-validation.json)。尚未在真机验证菜单展开、动画和视觉效果，验收步骤见 [DEVICE-TESTING.md](DEVICE-TESTING.md)。

Apple 官方嵌套菜单示例：[Menu](https://developer.apple.com/documentation/swiftui/menu)。
