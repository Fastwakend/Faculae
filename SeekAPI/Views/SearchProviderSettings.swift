import SwiftUI
import SeekCore

@MainActor
struct SearchProvidersSection: View {
    let store: AppStore
    @Binding var isReordering: Bool
    let isSortingAnotherSection: Bool
    let onEdit: (SearchProvider) -> Void
    let onDelete: (SearchProvider) -> Void
    var body: some View {
        Section {
            ForEach(store.searchProviders) { provider in
                Button { if !isReordering && !isSortingAnotherSection { onEdit(provider) } } label: {
                    HStack(spacing: 13) {
                        Image(systemName: "globe").font(.title2).frame(width: 34)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(provider.name).foregroundStyle(.primary)
                            Text(provider.kind.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if provider.id == store.selectedSearchProviderID { Text("当前").font(.caption).foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .disabled(store.hasActiveGenerations)
                .moveDisabled(!isReordering || store.hasActiveGenerations)
                .contextMenu {
                    if !isReordering && !isSortingAnotherSection {
                    Button("设为当前", systemImage: "checkmark") { store.selectSearchProvider(provider.id) }
                    Button("编辑", systemImage: "pencil") { onEdit(provider) }
                    Button("删除", systemImage: "trash", role: .destructive) { onDelete(provider) }
                        .disabled(store.hasActiveGenerations)
                    }
                }
            }
            .onMove { store.moveSearchProviders(fromOffsets: $0, toOffset: $1) }
            Button { onEdit(SearchProvider()) } label: { Label("添加搜索提供商", systemImage: "plus.circle").padding(.vertical, 6) }
                .disabled(store.hasActiveGenerations || isReordering || isSortingAnotherSection)
        } header: {
            ReorderSectionHeader(title: "搜索提供商", isReordering: $isReordering,
                canReorder: store.searchProviders.count > 1 && !store.hasActiveGenerations,
                accessibilityID: "settings.searchProviders.reorder")
        } footer: {
            Text("搜索服务与聊天模型独立配置。点排序后拖动右侧把手，顺序同步到聊天联网搜索菜单。搜索词发送至搜索服务，检索资料再交给当前模型。")
        }
    }
}

@MainActor
struct SearchProviderEditor: View {
    let store: AppStore
    @State private var provider: SearchProvider
    @State private var key = ""
    @State private var error: String?
    @State private var query = "DeepSeek 最新公告"
    @State private var results: [SearchResult] = []
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var keyLoaded = false
    @State private var makeCurrent = false
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, initial: SearchProvider) {
        self.store = store; _provider = State(initialValue: initial)
    }
    var body: some View {
        SettingsScaffold(title: "搜索提供商", onSave: save, saveDisabled: testing || store.hasActiveGenerations) {
            Form {
                Section("连接") {
                    TextField("显示名称", text: $provider.name)
                    Picker("接口类型", selection: $provider.kind) {
                        ForEach(SearchProviderKind.allCases) { Text($0.title).tag($0) }
                    }
                    .onChange(of: provider.kind) { old, new in
                        if provider.name == old.title { provider.name = new.title }
                        provider.endpoint = new.endpoint; key = ""; results = []; error = nil
                    }
                    TextField("完整搜索接口 HTTPS URL", text: $provider.endpoint, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .font(.system(.footnote, design: .monospaced))
                    SecureField("API Key（SearXNG 可留空）", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SeekSwitch("保存后设为当前搜索服务", isOn: $makeCurrent)
                }
                .disabled(testing)
                Section {
                    Stepper("结果数：\(provider.count)", value: $provider.count, in: 1...10)
                    if [.deepSeek, .tavily].contains(provider.kind) {
                        SeekSwitch("返回网页正文", isOn: $provider.includeContent)
                    }
                    if provider.kind == .deepSeek {
                        Stepper("补充抓取前 \(provider.fetchPages) 个网页", value: $provider.fetchPages, in: 0...3)
                        Text("Search 使用 /v1/tools/search；输入完整网页链接时直接调用同一服务的 /v1/tools/fetch。搜索缺少正文时，可额外抓取前几条。搜索和抓取可能分别按次计费。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Link("DeepSeek 官方使用指南", destination: URL(string: "https://api-docs.deepseek.com/zh-cn/guides/search/")!)
                    }
                } header: { Text("检索") } footer: {
                    Text("只在聊天开启联网、或主动点击测试时调用。SearXNG 实例需要允许 JSON 输出。Key 独立保存在系统钥匙串。")
                }
                .disabled(testing)
                if provider.kind == .custom { customConfiguration.disabled(testing) }
                Section {
                    TextField(provider.kind == .deepSeek ? "测试问题或网页链接" : "测试搜索词", text: $query, axis: .vertical)
                    Button(action: test) {
                        HStack { Label("测试搜索", systemImage: "magnifyingglass"); Spacer(); if testing { ProgressView() } }
                    }.disabled(testing || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if testing { Button("取消测试", role: .cancel) { testTask?.cancel() } }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                    ForEach(Array(results.enumerated()), id: \.offset) { _, result in
                        VStack(alignment: .leading, spacing: 4) {
                            if let url = WebSearch.safeResultURL(result.url) { Link(result.title, destination: url) }
                            Text(result.snippet.isEmpty ? String(result.content.prefix(180)) : result.snippet)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                } header: { Text("连接测试") }
            }
        }
        .task {
            guard !keyLoaded else { return }; keyLoaded = true
            makeCurrent = provider.id == store.selectedSearchProviderID
            do { key = try store.readSearchKey(provider) } catch { self.error = error.localizedDescription }
        }
        .onDisappear { testTask?.cancel() }
    }
    private var customConfiguration: some View {
        Section {
            Picker("请求方法", selection: $provider.method) { Text("POST").tag("POST"); Text("GET").tag("GET") }
            if provider.method == "POST" {
                TextField("请求 JSON，使用 {{query}} 占位符", text: $provider.bodyTemplate, axis: .vertical)
                    .font(.system(.caption, design: .monospaced)).lineLimit(3...8)
            } else { TextField("查询参数名", text: $provider.queryParameter) }
            TextField("认证头名（留空不发送 Key）", text: $provider.keyHeader)
            TextField("Key 前缀（例如 Bearer 加空格）", text: $provider.keyPrefix)
            TextField("结果数组路径", text: $provider.resultsPath)
            TextField("标题字段路径", text: $provider.titlePath)
            TextField("链接字段路径", text: $provider.urlPath)
            TextField("摘要字段路径", text: $provider.snippetPath)
            TextField("正文字段路径（可留空）", text: $provider.contentPath)
        } header: { Text("请求与 JSON 结构") } footer: {
            Text("路径支持 data.results、items[0].title 和 JSON Pointer。数组内的字段路径从每条结果开始；顶层数组填写 $。占位符在 JSON 解析后替换，支持带引号的搜索词。")
        }
        .textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func save() {
        do {
            try store.saveSearchProvider(provider, key: key)
            if makeCurrent { store.selectSearchProvider(provider.id) }
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }
    private func test() {
        testing = true; results = []; error = nil
        testTask = Task {
            defer { testing = false }
            do {
                let found = try await store.previewSearch(provider, key: key, query: query)
                try Task.checkCancellation()
                results = found
                if found.isEmpty { error = "连接成功，未找到匹配结果。" }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
