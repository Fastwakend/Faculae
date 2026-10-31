import SwiftUI
import SeekCore

@MainActor
struct ProfilesView: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    // Routes live on the settings screen, outside List's recycled sections.
    // Push editors within its NavigationStack rather than stacking another
    // modal on the settings sheet (which could dismiss the whole settings flow).
    @State private var editing: ProviderRoute?
    @State private var deleting: ProviderRoute?
    @State private var reordering: ProviderList?

    private enum ProviderList { case suppliers, search }

    private func sorting(_ list: ProviderList) -> Binding<Bool> {
        Binding(get: { reordering == list }, set: { reordering = $0 ? list : nil })
    }

    private enum ProviderRoute: Identifiable, Hashable {
        case model(APIProfile)
        case search(SearchProvider)

        var id: String {
            switch self {
            case .model(let profile): return "model-" + profile.id.uuidString
            case .search(let provider): return "search-" + provider.id.uuidString
            }
        }

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }

        var deletionMessage: String {
            switch self {
            case .model: return "将移除该供应商、其模型配置和对应的 Key。已有聊天记录会保留。"
            case .search: return "将移除该搜索提供商及其 Key。已有回复中的网页来源会保留。"
            }
        }
    }

    var body: some View {
        SettingsScaffold(title: "API 设置") {
            List {
                Section {
                    ForEach(store.profiles) { profile in
                        Button { if reordering == nil { editing = .model(profile) } } label: {
                            HStack(spacing: 13) {
                                ModelLogo(model: profile.selectedModel, provider: profile.provider, size: 34)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(profile.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Color(uiColor: .label))
                                    Text("\(profile.models.count) 个模型 · " + profile.selectedModel.displayTitle)
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if profile.id == store.selectedProfileID {
                                    Text("当前").font(.system(size: 10, weight: .medium)).foregroundStyle(Color(uiColor: .label))
                                        .padding(.horizontal, 7).padding(.vertical, 4)
                                        .background(SeekTheme.surface, in: Capsule())
                                }
                                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .disabled(store.hasActiveGenerations)
                        .moveDisabled(reordering != .suppliers || store.hasActiveGenerations)
                        .contextMenu {
                            if reordering == nil {
                            Button { editing = .model(profile) } label: { Label("编辑供应商", systemImage: "pencil") }
                            Button(role: .destructive) { deleting = .model(profile) } label: {
                                Label("删除供应商", systemImage: "trash")
                            }
                            .disabled(store.profiles.count <= 1 || store.hasActiveGenerations)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if store.profiles.count > 1 && reordering == nil {
                                Button(role: .destructive) { deleting = .model(profile) } label: {
                                    Label("删除", systemImage: "trash").foregroundStyle(.white)
                                }
                                .labelStyle(.titleAndIcon)
                                .buttonStyle(.automatic)
                                .tint(.red)
                                .disabled(store.hasActiveGenerations)
                            }
                        }
                    }
                    .onMove { store.moveProfiles(fromOffsets: $0, toOffset: $1) }
                    Button { editing = .model(APIProfile(name: "自定义供应商", provider: .openAI)) } label: {
                        Label("添加供应商", systemImage: "plus.circle").padding(.vertical, 6)
                    }
                    .disabled(store.hasActiveGenerations || reordering != nil)
                } header: {
                    ReorderSectionHeader(title: "供应商", isReordering: sorting(.suppliers),
                        canReorder: store.profiles.count > 1 && !store.hasActiveGenerations,
                        accessibilityID: "settings.suppliers.reorder")
                } footer: {
                    Text("点排序后拖动右侧把手调整顺序，同步到聊天的模型选择菜单。")
                }
                SearchProvidersSection(store: store, isReordering: sorting(.search),
                    isSortingAnotherSection: reordering == .suppliers,
                    onEdit: { editing = .search($0) }, onDelete: { deleting = .search($0) })
            }
            .environment(\.editMode, Binding(get: { reordering == nil ? .inactive : .active },
                set: { if !$0.isEditing { reordering = nil } }))
        }
        .buttonStyle(.plain)
        .onChange(of: store.hasActiveGenerations) { _, active in if active { reordering = nil } }
        .navigationDestination(item: $editing) { route in
            switch route {
            case .model(let profile): ProfileEditor(store: store, initialProfile: profile)
            case .search(let provider): SearchProviderEditor(store: store, initial: provider)
            }
        }
        .confirmationDialog("删除这个提供商？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除服务和 Key", role: .destructive) {
                do {
                    switch deleting {
                    case .model(let profile): try store.deleteProfile(profile)
                    case .search(let provider): try store.deleteSearchProvider(provider)
                    case nil: break
                    }
                } catch { store.notice = error.localizedDescription }
                deleting = nil
            }
        } message: { Text(deleting?.deletionMessage ?? "") }
    }
}

@MainActor
private struct ProfileEditor: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: APIProfile
    @State private var key = ""
    @State private var revealsKey = false
    @State private var modelIDs: [String] = []
    @State private var fetching = false
    @State private var modelTask: Task<Void, Never>?
    @State private var errorText: String?
    @State private var loadedKey = false
    @State private var showsAddModel = false
    @State private var newModelID = ""
    @State private var showsDeleteProfile = false
    @State private var reordersModels = false

    private var isExistingProfile: Bool { store.profiles.contains { $0.id == profile.id } }

    init(store: AppStore, initialProfile: APIProfile) {
        self.store = store
        _profile = State(initialValue: initialProfile)
    }

    var body: some View {
        SettingsScaffold(title: "编辑供应商", onSave: save, saveDisabled: fetching || store.hasActiveGenerations) {
            Form {
                Section {
                    TextField("显示名称", text: $profile.name)
                    Picker("API 协议", selection: $profile.provider) {
                        ForEach(APIProvider.allCases) { provider in Text(provider.title).tag(provider) }
                    }
                    .onChange(of: profile.provider) { _, provider in
                        profile.baseURL = provider.defaultBaseURL
                        key = ""
                        modelIDs = []
                        errorText = nil
                    }
                    TextField("API Base URL", text: $profile.baseURL, axis: .vertical)
                        .font(.system(size: 13, design: .monospaced))
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings.baseURL")
                } header: { Text("服务") } footer: {
                    Text(baseHint + "\n仅支持 HTTPS；反向代理可填写带路径前缀的地址。")
                }
                .disabled(fetching)
    
                Section {
                    HStack {
                        Group {
                            if revealsKey { TextField("API Key", text: $key) }
                            else { SecureField("API Key", text: $key) }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                        .accessibilityIdentifier("settings.apiKey")
                        Button { revealsKey.toggle() } label: {
                            Image(systemName: revealsKey ? "eye.slash" : "eye").frame(width: 36, height: 36)
                        }
                        .buttonStyle(.borderless).accessibilityLabel(revealsKey ? "隐藏 Key" : "显示 Key")
                    }
                } header: { Text("认证") } footer: {
                    Text("留空并保存会移除这个服务的 Key。切换协议会清空编辑框中的 Key，请填写对应服务的凭据。")
                }
                .disabled(fetching)
    
                Section {
                    ForEach(profile.models) { model in
                        NavigationLink {
                            ModelSettingsView(profile: $profile, initialModel: model)
                        } label: {
                            HStack(spacing: 12) {
                                ModelLogo(model: model, provider: profile.provider, size: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(model.displayTitle).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                    if model.displayTitle != model.model {
                                        Text(model.model).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                if model.id == profile.selectedModelID {
                                    Text("默认").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .moveDisabled(!reordersModels || fetching || store.hasActiveGenerations)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if profile.models.count > 1 && !reordersModels {
                                Button(role: .destructive) {
                                    do { try profile.removeModel(model.id) }
                                    catch { errorText = error.localizedDescription }
                                } label: {
                                    Label("删除", systemImage: "trash").foregroundStyle(.white)
                                }
                                .labelStyle(.titleAndIcon)
                                .buttonStyle(.automatic)
                                .tint(.red)
                                .accessibilityLabel("删除模型 \(model.displayTitle)")
                            }
                        }
                    }
                    .onMove { source, destination in
                        guard !fetching, !store.hasActiveGenerations else { return }
                        if profile.moveModels(fromOffsets: source, toOffset: destination) { Haptics.shared.play(.listItem) }
                    }
                    Button { newModelID = ""; showsAddModel = true } label: {
                        Label("手动添加模型", systemImage: "plus.circle")
                    }
                    .accessibilityIdentifier("settings.models.add")
                    Button(action: fetchModels) {
                        HStack {
                            Label("读取模型 / 测试连接", systemImage: "arrow.triangle.2.circlepath")
                            Spacer()
                            if fetching { ProgressView() }
                        }
                    }
                    .disabled(fetching || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if !modelIDs.isEmpty {
                        NavigationLink {
                            ModelPickerView(profile: $profile, availableIDs: modelIDs)
                        } label: {
                            Label("从列表添加（\(modelIDs.count) 个）", systemImage: "list.bullet")
                        }
                    }
                    if let errorText { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                } header: {
                    ReorderSectionHeader(title: "模型（\(profile.models.count)）", isReordering: $reordersModels,
                        canReorder: profile.models.count > 1 && !fetching && !store.hasActiveGenerations,
                        accessibilityID: "settings.models.reorder")
                } footer: {
                    Text("点模型可设置参数和默认项；左滑移除模型。点排序后拖动右侧把手调整顺序。模型顺序与其他修改在右上角保存后一并同步到聊天菜单。")
                }
                .disabled(fetching)
                if isExistingProfile {
                    Section {
                        Button(role: .destructive) { showsDeleteProfile = true } label: {
                            Label("删除供应商", systemImage: "trash")
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        }
                        .buttonStyle(.automatic)
                        .disabled(fetching || store.hasActiveGenerations || store.profiles.count <= 1)
                        .accessibilityIdentifier("settings.supplier.delete")
                    } footer: {
                        Text(store.profiles.count <= 1 ? "至少保留一个供应商；可先添加其他供应商。" : "删除供应商及其模型配置和 Key，保留已有聊天记录。")
                    }
                }
            }
            .environment(\.editMode, Binding(get: { reordersModels ? .active : .inactive },
                set: { reordersModels = $0.isEditing }))
        }
        .onAppear {
            guard !loadedKey else { return }
            loadedKey = true
            do { key = try store.readKey(for: profile) }
            catch { errorText = error.localizedDescription }
        }
        .onDisappear { modelTask?.cancel() }
        .confirmationDialog("删除供应商“\(profile.name)”？", isPresented: $showsDeleteProfile, titleVisibility: .visible) {
            Button("删除供应商和 Key", role: .destructive) {
                do {
                    try store.deleteProfile(profile)
                    dismiss()
                } catch { errorText = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("此操作会移除该供应商的全部模型和 Key。已有聊天记录会保留。") }
        .alert("添加模型", isPresented: $showsAddModel) {
            TextField("模型 ID", text: $newModelID)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("添加") {
                do { try profile.addModel(newModelID); errorText = nil }
                catch { errorText = error.localizedDescription }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var baseHint: String {
        switch profile.provider {
        case .openAI: return "例如 https://api.openai.com/v1 或 https://api.deepseek.com；自动追加 /chat/completions。"
        case .gemini: return "例如 https://generativelanguage.googleapis.com/v1beta；使用 Gemini 原生协议。"
        case .claude: return "例如 https://api.anthropic.com/v1；自动追加 /messages。"
        }
    }

    private func save() {
        profile.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !profile.name.isEmpty else { errorText = "请填写服务名称。"; return }
        do { try store.saveProfile(profile, key: key); dismiss() }
        catch { errorText = redact(error.localizedDescription) }
    }

    private func fetchModels() {
        fetching = true
        errorText = nil
        let draftProfile = profile
        let draftKey = key
        modelTask = Task {
            defer { fetching = false }
            do {
                let models = try await store.fetchModels(profile: draftProfile, key: draftKey)
                guard !Task.isCancelled else { return }
                modelIDs = models
            } catch {
                guard !Task.isCancelled else { return }
                errorText = redact(error.localizedDescription)
            }
        }
    }

    private func redact(_ text: String) -> String {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanKey.isEmpty ? text : text.replacingOccurrences(of: cleanKey, with: "[Key]")
    }
}
