# Faculae 应用名称接入

Faculae 是 facula 的复数，意为太阳表面的明亮光斑。用户已选定这个名称，继续使用已确认的三颗端正星芒图标。

已更新主应用的桌面 / 系统显示名称、分享扩展名称和导入提示、实时活动扩展名称、设置页应用介绍、相机 / 相册 / 通知 / 实时活动的权限引导文案，以及导出文件的品牌前缀。

图标母图现存放于 `tools/artwork/facula/`，使用 `python tools/create_assets.py` 或 `python tools/create_facula_icons.py --install` 重建。旧的 `create_conflux_icons.py` 入口仅为兼容既有命令，转发至相同的 Faculae 确认稿；不会重新安装已放弃的 C 字母图标。

这是同一应用的对外名称变更，保留现有 `app.seekapi.ios` Bundle ID、App Group、钥匙串命名空间、后台任务标识、`seekapi://` 深链接、`Application Support/SeekAPI/` 数据路径及 Xcode / SwiftPM 工程名称。这样后续以相同签名身份覆盖安装时可继续使用原有配置、附件、对话和系统集成，无需数据迁移。

名称最终采用 Faculae；2.3.3 (35) 将此名称编译进主应用和两个扩展，并在 WSL 中编译浅色、深色图标为原生资源目录。此前名称确认阶段只更新源码；本次按用户要求生成新版 IPA。已发布的版本化产物保留原样。详见 [2.3.3 说明](UI-2.3.3.md) 和 [图标说明](ICON-FACULA.md)。

验证范围：主应用两套 Info.plist 的显示名称及一致性、分享 / 实时活动扩展名称、源码中旧的用户可见品牌文案已替换、存储与签名标识保持兼容、两张图标 SHA-256 不变、图标资源重建、Xcode 项目静态检查，以及源码 ZIP 内容和 CRC。未声称真机安装验证。
