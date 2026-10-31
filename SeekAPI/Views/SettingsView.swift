import SwiftUI
import SeekCore

@MainActor
struct SettingsView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("chatTextSize") private var textSize = ChatTextSize.standard.rawValue

    var body: some View {
        SettingsScaffold(title: "设置", isRoot: true) {
            ScrollView {
                VStack(spacing: 28) {
                    SettingsSection(title: "服务") {
                        NavigationLink { ProfilesView(store: store) } label: {
                            SettingsRow(icon: "person.crop.circle", title: "API 与模型", value: store.selectedProfile.name)
                        }
                        SettingsDivider()
                        NavigationLink { UsageSettingsView(store: store) } label: {
                            SettingsRow(icon: "chart.bar.xaxis", title: "余额用量")
                        }
                        SettingsDivider()
                        NavigationLink { DataSettingsView(store: store) } label: {
                            SettingsRow(icon: "externaldrive", title: "数据管理")
                        }
                    }
                    SettingsSection(title: "应用") {
                        SettingsRow(icon: "globe", title: "语言", value: "简体中文", chevron: false)
                        SettingsDivider()
                        Menu {
                            Picker("外观", selection: $appearance) {
                                ForEach(AppAppearance.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                        } label: {
                            SettingsRow(icon: "sun.max", title: "外观",
                                        value: (AppAppearance(rawValue: appearance) ?? .system).title,
                                        accessory: "chevron.up.chevron.down")
                        }
                        SettingsDivider()
                        NavigationLink { TextSettingsView() } label: {
                            SettingsRow(icon: "textformat.size", title: "字体大小",
                                        value: (ChatTextSize(rawValue: textSize) ?? .standard).title)
                        }
                        SettingsDivider()
                        NavigationLink { BackgroundSettingsView(store: store) } label: {
                            SettingsRow(icon: "arrow.triangle.2.circlepath", title: "后台生成")
                        }
                        SettingsDivider()
                        NavigationLink { HapticSettingsView() } label: {
                            SettingsRow(icon: "waveform.path", title: "触觉反馈")
                        }
                        SettingsDivider()
                        NavigationLink { PersonalizationView(profile: store.userProfile) } label: {
                            SettingsRow(icon: "wand.and.stars", title: "个性化")
                        }
                    }
                    SettingsSection(title: "关于") {
                        SettingsRow(icon: "info.circle", title: "应用版本", value: appVersion, chevron: false)
                        SettingsDivider()
                        NavigationLink { SystemPermissionsView(store: store) } label: {
                            SettingsRow(icon: "checkmark.shield", title: "系统权限")
                        }
                        SettingsDivider()
                        NavigationLink { PrivacySettingsView() } label: {
                            SettingsRow(icon: "hand.raised", title: "隐私与数据")
                        }
                    }
                    Text("Faculae · 让喜欢的模型，住进同一个对话框")
                        .font(.footnote).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 16)
                .padding(.top, 18)
            }
        }
        .buttonStyle(.plain)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.3.3"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "35"
        return "\(version) (\(build))"
    }
}

@MainActor
private struct SettingsRow: View {
    let icon: String
    let title: String
    var value: String? = nil
    var chevron = true
    var accessory = "chevron.right"

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .regular))
                .frame(width: 25)
                .accessibilityHidden(true)
            Text(title).font(.body)
            Spacer(minLength: 8)
            if let value {
                Text(value).font(.body).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if chevron {
                Image(systemName: accessory).font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 18)
        .padding(.vertical, 17)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0, content: content)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        }
    }
}

private struct SettingsDivider: View {
    var body: some View { Divider().padding(.leading, 57).padding(.trailing, 18) }
}

@MainActor
private struct TextSettingsView: View {
    @AppStorage("chatTextSize") private var textSize = ChatTextSize.standard.rawValue
    @ScaledMetric(relativeTo: .body) private var sampleSize: CGFloat = 17

    var body: some View {
        SettingsScaffold(title: "字体大小") {
            Form {
                Section {
                    Picker("字体大小", selection: $textSize) {
                        ForEach(ChatTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                } footer: { Text("调整消息与输入文字的大小，同时跟随系统的动态字体设置。") }
                Section("预览") {
                    Text("你好，我能帮什么忙吗？\n\n把想法写下来，让对话自然发生。")
                        .font(.system(size: sampleSize * (ChatTextSize(rawValue: textSize) ?? .standard).scale))
                        .lineSpacing(6)
                        .padding(.vertical, 16)
                }
            }
        }
    }
}

@MainActor
private struct DataSettingsView: View {
    let store: AppStore
    @State private var confirmsDelete = false

    var body: some View {
        SettingsScaffold(title: "数据管理") {
            Form {
                Section {
                    LabeledContent("本地对话", value: "\(store.conversations.count) 条")
                    LabeledContent("API 服务", value: "\(store.profiles.count) 个")
                    LabeledContent("已添加模型", value: "\(store.profiles.reduce(0) { $0 + $1.models.count }) 个")
                }
                Section {
                    ShareLink(item: store.sortedConversations.map(\.markdown).joined(separator: "\n\n---\n\n")) {
                        Label("导出全部对话", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.conversations.isEmpty || store.hasActiveGenerations)
                    Button(role: .destructive) { confirmsDelete = true } label: {
                        Label("清空所有对话", systemImage: "trash")
                    }
                        .disabled(store.conversations.isEmpty || store.hasActiveGenerations)
                } footer: {
                    Text("导出包含聊天文本和附件名称，不包含附件原文件或 API Key。清空对话会同时删除聊天附件，保留 API 服务和 Key。")
                }
            }
        }
        .confirmationDialog("清空所有本地对话？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("清空所有对话", role: .destructive) { store.deleteAllConversations() }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作无法撤销。需要保留的内容请先导出。") }
    }
}

@MainActor
private struct PrivacySettingsView: View {
    var body: some View {
        SettingsScaffold(title: "隐私与数据") {
            Form {
                Section("API 连接") {
                    Text("对话与选择发送的附件直接发送至你配置的 HTTPS API。服务商的数据保留和计费规则由对应服务决定。")
                    Text("切换 API 后继续同一对话，会向新服务发送这条对话的有效上下文。")
                }
                Section("本地保存") {
                    Text("API Key 保存在本机系统钥匙串。对话、服务配置和显示偏好保存在本机，聊天导出不包含 Key。")
                    Text("请只填写你信任的 API 地址。使用自己的 Key，勿将其发送给他人。")
                }
                Section("关于应用") {
                    Text("Faculae 是独立的原生 API 客户端，与参考应用和各模型服务商无隶属关系。")
                    DisclosureGroup("模型图标许可") {
                        Text(logoLicense).font(.caption).textSelection(.enabled)
                    }
                }
            }
        }
    }
    private var logoLicense: String {
        guard let url = Bundle.main.url(forResource: "ModelLogoLicenses", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "Lobe Icons · MIT License · Copyright (c) 2023 LobeHub" }
        return text
    }

}
