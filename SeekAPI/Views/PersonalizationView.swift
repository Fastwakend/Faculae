import SwiftUI
import PhotosUI

@MainActor
struct PersonalizationView: View {
    let profile: UserProfileSettings
    @State private var name: String
    @State private var avatarID: UUID?
    @State private var photo: PhotosPickerItem?
    @State private var importing = false
    @State private var error: String?
    @State private var imported = Set<UUID>()
    @State private var importTask: Task<Void, Never>?
    @AppStorage("showReasoning") private var showReasoning = true
    @AppStorage("automaticallyScroll") private var automaticallyScroll = true
    @AppStorage("portraitLocked") private var portraitLocked = false
    @Environment(\.dismiss) private var dismiss

    init(profile: UserProfileSettings) {
        self.profile = profile
        _name = State(initialValue: profile.name)
        _avatarID = State(initialValue: profile.avatarID)
    }

    var body: some View {
        SettingsScaffold(title: "个性化", onSave: save, saveDisabled: importing) {
            Form {
                Section {
                    HStack(spacing: 16) {
                        UserAvatar(avatarID: avatarID, size: 64)
                        VStack(alignment: .leading, spacing: 8) {
                            PhotosPicker(selection: $photo, matching: .images) { Label("从相册选择头像", systemImage: "photo") }
                        }
                    }
                    .disabled(importing)
                    if importing { ProgressView("正在导入头像") }
                    TextField("用户名", text: $name).textInputAutocapitalization(.never)
                        .autocorrectionDisabled().accessibilityIdentifier("personalization.username")
                } header: { Text("头像与用户名") } footer: {
                    Text("显示在对话列表下方，仅保存在本机，不会发送给模型。用户名最多 40 个字符，留空恢复为“本地空间”。点击右上角保存生效。")
                }
                Section {
                    SeekSwitch("显示思考过程", isOn: $showReasoning)
                    SeekSwitch("自动跟随回答", isOn: $automaticallyScroll)
                } footer: {
                    Text("仅展示模型实际返回的思考内容。阅读历史消息时，手动向上滚动会暂停自动跟随。")
                }
                Section {
                    SeekSwitch("开启竖屏锁定", isOn: $portraitLocked)
                } footer: { Text("开启后保持竖屏显示，不随设备方向旋转。") }
                if let error { Section { Text(error).font(.footnote).foregroundStyle(.red) } }
            }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            beginImport {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                return try await ModelIconStore.shared.importImage(data)
            }
        }
        .onChange(of: portraitLocked) { _, _ in OrientationPolicy.apply() }
        .onDisappear {
            importTask?.cancel()
            let unused = imported.subtracting([profile.avatarID].compactMap { $0 })
            Task { for id in unused { await ModelIconStore.shared.remove(id) } }
        }
    }

    private func beginImport(_ action: @escaping () async throws -> UUID) {
        importTask?.cancel()
        importing = true; error = nil
        importTask = Task {
            defer { importing = false }
            do {
                let id = try await action()
                if Task.isCancelled { await ModelIconStore.shared.remove(id); return }
                imported.insert(id); avatarID = id
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }

    private func save() {
        do { try profile.save(name: name, avatarID: avatarID); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

@MainActor
struct UserAvatar: View {
    let avatarID: UUID?
    var size: CGFloat = 34
    var body: some View {
        Group {
            if let avatarID, let image = ModelIconStore.image(for: avatarID) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().scaledToFit()
                    .foregroundStyle(SeekTheme.blue.opacity(0.8))
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityLabel("用户头像")
    }
}
