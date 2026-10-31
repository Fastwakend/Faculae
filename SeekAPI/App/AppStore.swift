import Foundation
import Observation
import SeekCore

@MainActor
@Observable
final class AppStore {
    private(set) var profiles: [APIProfile] = APIProfile.presets
    private(set) var conversations: [Conversation] = []
    private(set) var selectedProfileID = UUID()
    private(set) var selectedConversationID: UUID?
    private let generationTasks = ConversationGenerationTasks()
    var isStreaming: Bool { generationTasks.contains(selectedConversationID) }
    var hasActiveGenerations: Bool { !generationTasks.isEmpty }
    func isGenerating(_ conversationID: UUID) -> Bool { generationTasks.contains(conversationID) }
    private(set) var usageRecords: [UsageRecord] = []
    private(set) var balanceConfigurations: [UUID: BalanceConfiguration] = [:]
    private(set) var balances: [UUID: BalanceState] = [:]
    let backgroundServices = GenerationServices.shared
    let userProfile = UserProfileSettings()
    private(set) var searchProviders: [SearchProvider] = []
    private(set) var selectedSearchProviderID: UUID?
    var searchEnabled = UserDefaults.standard.bool(forKey: "search.enabled") {
        didSet { UserDefaults.standard.set(searchEnabled, forKey: "search.enabled") }
    }
    var selectedSearchProvider: SearchProvider? { searchProviders.first { $0.id == selectedSearchProviderID } }
    @ObservationIgnored private let searchKeychain = KeychainStore(namespace: "search-keys")
    @ObservationIgnored private let searchClient = WebSearchClient()
    var notice: String?
    let externalFiles = ExternalFileImport()
    var draftAttachments: [ChatAttachment] = []
    @ObservationIgnored private let persistence = PersistenceStore()
    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private let client = AIStreamingClient()
    @ObservationIgnored private var runs: [UUID: ReplyRun] = [:]
    @ObservationIgnored private var recoveryRequired = false

    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var balanceLoop: Task<Void, Never>?

    init() {
        selectedProfileID = profiles[0].id
        do {
            if let state = try persistence.load() {
                profiles = state.profiles
                conversations = state.conversations
                usageRecords = state.usageRecords ?? []
                balanceConfigurations = state.balanceConfigurations ?? [:]
                searchProviders = state.searchProviders ?? []
                selectedSearchProviderID = state.selectedSearchProviderID ?? searchProviders.first?.id
                selectedProfileID = profiles.contains(where: { $0.id == state.selectedProfileID }) ? state.selectedProfileID : profiles[0].id
                selectedConversationID = state.selectedConversationID
                for i in conversations.indices {
                    for j in conversations[i].messages.indices where conversations[i].messages[j].status == .streaming {
                        conversations[i].messages[j].status = .stopped
                        conversations[i].messages[j].error = "上次回复因进程结束而中断，已保留收到的内容。可手动重新生成。"
                    }
                }
                if let conversation = currentConversation {
                    if let index = profiles.firstIndex(where: { $0.id == conversation.profileID }) {
                        selectedProfileID = profiles[index].id
                        profiles[index].restoreModel(for: conversation)
                    }
                } else {
                    selectedConversationID = nil
                }
            }
        } catch {
            recoveryRequired = true
            notice = "本地记录读取失败，原文件已保留。为避免覆盖，暂时停止自动保存。请导出或备份 Application Support/SeekAPI/state.json 后再处理。"
        }
        backgroundServices.onExpiration = { [weak self] reason in
            self?.stopAllGenerations(reason: reason)
        }
        backgroundServices.onReplyExpiration = { [weak self] replyID, reason in
            guard let self, let run = self.runs.values.first(where: { $0.messageID == replyID }) else { return }
            self.stopGeneration(reason: reason, conversationID: run.chatID)
        }
        backgroundServices.onCheckpoint = { [weak self] in self?.checkpointGeneration() }
        backgroundServices.isGenerating = { [weak self] in self?.hasActiveGenerations == true }
        Task { await backgroundServices.reconcileInterruptedActivities() }
        if !recoveryRequired {
            let ids = Set(conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id))
            let iconIDs = Set(profiles.flatMap(\.models).compactMap(\.customIconID) +
                              conversations.flatMap(\.messages).compactMap(\.customIconID) + [userProfile.avatarID].compactMap { $0 })
            Task {
                await AttachmentStore.shared.prune(keeping: ids)
                await ModelIconStore.shared.prune(keeping: iconIDs)
            }
        }
    }

    var selectedProfile: APIProfile { profiles.first { $0.id == selectedProfileID } ?? profiles[0] }
    var currentConversation: Conversation? { conversations.first { $0.id == selectedConversationID } }
    var sortedConversations: [Conversation] {
        conversations.sorted { a, b in a.isPinned != b.isPinned ? a.isPinned : a.updatedAt > b.updatedAt }
    }

    func readKey(for profile: APIProfile) throws -> String { try keychain.read(for: profile.id) }

    func readSearchKey(_ provider: SearchProvider) throws -> String { try searchKeychain.read(for: provider.id) }

    func moveProfiles(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !hasActiveGenerations,
              ListOrdering.move(&profiles, fromOffsets: source, toOffset: destination) else { return }
        Haptics.shared.play(.listItem)
        persist()
    }

    func moveSearchProviders(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !hasActiveGenerations,
              ListOrdering.move(&searchProviders, fromOffsets: source, toOffset: destination) else { return }
        Haptics.shared.play(.listItem)
        persist()
    }

    func saveSearchProvider(_ provider: SearchProvider, key: String) throws {
        guard !hasActiveGenerations else { return }
        try WebSearch.validate(provider)
        try searchKeychain.save(key, for: provider.id)
        if let i = searchProviders.firstIndex(where: { $0.id == provider.id }) { searchProviders[i] = provider }
        else { searchProviders.append(provider) }
        if selectedSearchProvider == nil { selectedSearchProviderID = provider.id }
        persist()
    }
    func selectSearchProvider(_ id: UUID) {
        guard searchProviders.contains(where: { $0.id == id }) else { return }
        selectedSearchProviderID = id; persist()
    }
    func deleteSearchProvider(_ provider: SearchProvider) throws {
        guard !hasActiveGenerations else { return }
        try searchKeychain.delete(for: provider.id)
        searchProviders.removeAll { $0.id == provider.id }
        if selectedSearchProviderID == provider.id { selectedSearchProviderID = searchProviders.first?.id }
        if searchProviders.isEmpty { searchEnabled = false }
        persist()
    }
    func previewSearch(_ provider: SearchProvider, key: String, query: String) async throws -> [SearchResult] {
        try await searchClient.search(provider: provider, key: key, query: query)
    }

    func saveProfile(_ profile: APIProfile, key: String) throws {
        guard !hasActiveGenerations else { return }
        try RequestBuilder.validateAllModels(profile)
        try keychain.save(key, for: profile.id)
        balances[profile.id] = nil
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        selectProfile(profile.id)
    }

    func deleteProfile(_ profile: APIProfile) throws {
        guard profiles.count > 1, !hasActiveGenerations else { return }
        try keychain.delete(for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        balanceConfigurations[profile.id] = nil
        balances[profile.id] = nil
        if selectedProfileID == profile.id { selectProfile(profiles[0].id) }
        persist()
    }

    func selectProfile(_ id: UUID) {
        guard !isStreaming, profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        if let index = currentIndex {
            conversations[index].profileID = id
            conversations[index].modelID = selectedProfile.selectedModelID
        }
        persist()
    }

    func selectModel(profileID: UUID, modelID: UUID) {
        guard !isStreaming, let index = profiles.firstIndex(where: { $0.id == profileID }),
              profiles[index].selectModel(modelID) else { return }
        selectProfile(profileID)
    }

    func setReasoningLevel(_ level: ReasoningLevel) {
        guard !isStreaming, let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else { return }
        let normalized = profiles[index].normalizedReasoningLevel(level)
        guard profiles[index].reasoningLevel != normalized else { return }
        profiles[index].reasoningLevel = normalized
        persist()
    }

    func newConversation() {
        Haptics.shared.play()
        prepareConversationSwitch(to: nil)
        selectedConversationID = nil
        persist()
    }

    func branchConversation(at messageID: UUID) {
        guard let source = currentConversation else { return }
        do {
            let branch = try source.branched(through: messageID)
            conversations.insert(branch, at: 0)
            selectConversation(branch)
            Haptics.shared.play()
        } catch { notice = error.localizedDescription }
    }

    func selectConversation(_ conversation: Conversation) {
        prepareConversationSwitch(to: conversation.id)
        selectedConversationID = conversation.id
        selectedProfileID = profiles.first { $0.id == conversation.profileID }?.id ?? profiles[0].id
        if let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) {
            profiles[index].restoreModel(for: conversation)
        }
        persist()
    }

    func deleteConversation(_ id: UUID) {
        deleteConversations([id])
    }

    func deleteConversations(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids where generationTasks.contains(id) { stopGeneration(conversationID: id) }
        let removed = ConversationBatchActions.remove(ids, from: &conversations)
        if let selectedConversationID, ids.contains(selectedConversationID) { self.selectedConversationID = nil }
        if persist() { Task { await AttachmentStore.shared.remove(removed) } }
    }

    func setConversationsPinned(_ ids: Set<UUID>, pinned: Bool) {
        guard !ids.isEmpty else { return }
        ConversationBatchActions.setPinned(pinned, ids: ids, in: &conversations)
        persist()
    }

    func deleteAllConversations() {
        guard !hasActiveGenerations else { return }
        let removed = conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }
        conversations.removeAll()
        selectedConversationID = nil
        if persist() { Task { await AttachmentStore.shared.remove(removed) } }
    }

    func renameConversation(_ id: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].title = String(trimmed.prefix(100))
        persist()
    }

    func togglePin(_ id: UUID) {
        guard let index = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[index].isPinned.toggle()
        persist()
    }

    @discardableResult
    func send(_ text: String, attachments: [ChatAttachment] = []) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), !isStreaming else { return false }
        do {
            try RequestBuilder.validate(selectedProfile)
            guard !(try readKey(for: selectedProfile)).isEmpty else { throw APIError.missingKey }
            if selectedProfile.selectedModel.effectiveType == .imageGeneration {
                try ImageGenerationAPI.validateReferences(attachments)
                try selectedProfile.imageSettings.validate(provider: selectedProfile.provider)
            } else if searchEnabled {
                guard let provider = selectedSearchProvider else { throw APIError.provider("请先在 API 与模型设置中添加搜索提供商。") }
                guard !text.isEmpty else { throw APIError.provider("联网搜索需要输入问题或网页链接。") }
                _ = try WebSearch.request(provider: provider, key: readSearchKey(provider), query: text)
            }
        } catch { notice = error.localizedDescription; return false }
        if currentIndex == nil {
            let title = text.isEmpty ? (attachments.first?.name ?? "附件对话") : text.replacingOccurrences(of: "\n", with: " ")
            let conversation = Conversation(title: String(title.prefix(30)), profileID: selectedProfileID,
                                            modelID: selectedProfile.selectedModelID)
            conversations.insert(conversation, at: 0)
            selectedConversationID = conversation.id
        }
        guard let index = currentIndex else { return false }
        conversations[index].messages.append(ChatMessage(role: .user, content: text, attachments: attachments.isEmpty ? nil : attachments))
        Haptics.shared.play(.generation)
        startGeneration()
        return true
    }

    func regenerate() {
        guard !isStreaming, let index = currentIndex,
              conversations[index].messages.last?.role == .assistant else { return }
        do {
            try RequestBuilder.validate(selectedProfile)
            guard !(try readKey(for: selectedProfile)).isEmpty else { throw APIError.missingKey }
        } catch { notice = error.localizedDescription; return }
        let discarded = conversations[index].messages.removeLast().attachments ?? []
        let retained = Set(conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id))
        let removable = discarded.filter { !retained.contains($0.id) }
        if !removable.isEmpty { Task { await AttachmentStore.shared.remove(removable) } }
        startGeneration()
    }

    private func prepareConversationSwitch(to id: UUID?) {
        if let cancelled = generationTasks.switchConversation(from: selectedConversationID, to: id,
                                                              continues: backgroundServices.continueOnConversationSwitch) {
            stopGeneration(conversationID: cancelled)
        }
    }

    func stopGeneration(reason: String = "回复已停止", conversationID: UUID? = nil) {
        guard let chatID = conversationID ?? selectedConversationID, let run = runs.removeValue(forKey: chatID) else { return }
        generationTasks.cancel(chatID)
        updateMessage(chatID: chatID, messageID: run.messageID) {
            $0.status = .stopped
            if reason != "回复已停止" { $0.error = reason }
        }
        Haptics.shared.play(.generation)
        finishGeneration(run, status: reason)
        persist()
    }

    private func stopAllGenerations(reason: String) {
        for id in Array(runs.keys) { stopGeneration(reason: reason, conversationID: id) }
    }

    func enterBackground() {
        isInBackground = true
        balanceLoop?.cancel(); balanceLoop = nil
        backgroundServices.enterBackground()
        for run in runs.values { refreshActivity(run, force: true) }
        persist()
    }

    func enterForeground() {
        isInBackground = false
        externalFiles.checkInbox()
        backgroundServices.enterForeground()
        for run in runs.values { refreshActivity(run, force: true) }
        guard balanceLoop == nil else { return }
        balanceLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDueBalances()
                do { try await Task.sleep(for: .seconds(30)) } catch { break }
            }
        }
    }

    func openConversationURL(_ url: URL) {
        if url.isFileURL { externalFiles.open(url); return }
        guard url.scheme == "seekapi", url.host == "conversation",
              let id = UUID(uuidString: url.lastPathComponent),
              let chat = conversations.first(where: { $0.id == id }) else { return }
        selectConversation(chat)
    }

    func fetchModels(profile: APIProfile, key: String) async throws -> [String] {
        try await client.fetchModels(profile: profile, key: key)
    }

    @discardableResult
    func persist() -> Bool {
        guard !recoveryRequired else { return false }
        do {
            try persistence.save(AppSnapshot(profiles: profiles, conversations: conversations,
                                             selectedProfileID: selectedProfileID, selectedConversationID: selectedConversationID,
                                             usageRecords: usageRecords, balanceConfigurations: balanceConfigurations,
                                             searchProviders: searchProviders, selectedSearchProviderID: selectedSearchProviderID))
            return true
        } catch { notice = "本地保存失败：\(error.localizedDescription)"; return false }
    }

    private var currentIndex: Int? { conversations.firstIndex { $0.id == selectedConversationID } }

    private func startGeneration() {
        guard let index = currentIndex else { return }
        let profile = selectedProfile
        let key: String
        do { key = try readKey(for: profile) }
        catch { notice = error.localizedDescription; persist(); return }
        conversations[index].profileID = profile.id
        conversations[index].modelID = profile.selectedModelID
        let context = conversations[index].messages
        let isImageGeneration = profile.selectedModel.effectiveType == .imageGeneration
        let searchProvider = searchEnabled && !isImageGeneration ? selectedSearchProvider : nil
        let searchKey: String
        do { searchKey = try searchProvider.map { try readSearchKey($0) } ?? "" }
        catch { notice = error.localizedDescription; persist(); return }
        var pendingAssistant = ChatMessage(role: .assistant, status: .streaming, model: profile.model,
                                    modelProvider: profile.provider, modelIconStyle: profile.selectedModel.iconStyle,
                                    customIconID: profile.selectedModel.iconStyle == .custom ? profile.selectedModel.customIconID : nil,
                                    modelDisplayName: profile.selectedModel.displayName)
        if isImageGeneration {
            pendingAssistant.imageGenerationSettings = profile.imageSettings
            pendingAssistant.generationStage = "正在生成图像…"
        }
        let assistant = pendingAssistant
        let chatID = conversations[index].id
        conversations[index].messages.append(assistant)
        conversations[index].updatedAt = Date()
        let run = ReplyRun(chatID: chatID, messageID: assistant.id, profileID: profile.id)
        if searchProvider != nil { run.phase = "正在联网搜索" }
        if isImageGeneration { run.phase = "正在生成图像" }
        runs[chatID] = run
        backgroundServices.beginReply(attributes: ReplyActivityAttributes(replyID: assistant.id, conversationID: chatID,
            modelName: String(assistant.modelDisplayTitle.prefix(120)),
            supplierLogo: ModelLogo.brandName(model: profile.model, provider: profile.provider, iconStyle: profile.selectedModel.iconStyle), startedAt: assistant.createdAt))
        persist()

        generationTasks.start(conversationID: chatID, runID: run.id) { [weak self, client] token in
            do {
                var requestProfile = profile
                if let searchProvider, let self {
                    self.updateMessage(chatID: chatID, messageID: assistant.id) { $0.generationStage = "正在联网搜索…" }
                    self.refreshActivity(run, force: true)
                    let query = context.last(where: { $0.role == .user })?.content ?? ""
                    let sources = try await self.searchClient.search(provider: searchProvider, key: searchKey, query: query)
                    try Task.checkCancellation()
                    guard self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                    self.updateMessage(chatID: chatID, messageID: assistant.id) {
                        $0.searchProviderName = searchProvider.name
                        $0.searchSources = sources.map { SearchResult(title: $0.title, url: $0.url,
                            snippet: $0.snippet.isEmpty ? String($0.content.prefix(1800)) : $0.snippet,
                            siteName: $0.siteName, publishedDate: $0.publishedDate) }
                        $0.generationStage = sources.isEmpty ? "未找到匹配结果，正在生成回复…" : "已检索 \(sources.count) 条资料，正在生成回复…"
                    }
                    requestProfile.systemPrompt += WebSearch.context(sources)
                    run.phase = nil
                    self.refreshActivity(run, force: true)
                }
                if isImageGeneration {
                    let prompt = context.last(where: { $0.role == .user })?.content ?? ""
                    let result = try await client.generateImage(profile: profile, key: key, prompt: prompt,
                        attachments: context.last(where: { $0.role == .user })?.attachments ?? [])
                    guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else {
                        await AttachmentStore.shared.remove(result.attachments); return
                    }
                    self.updateMessage(chatID: chatID, messageID: assistant.id) {
                        $0.content = result.text.isEmpty ? "已生成图像。" : result.text
                        $0.attachments = result.attachments
                        $0.tokenUsage = result.usage
                        $0.generationStage = nil
                    }
                    self.refreshActivity(run, force: true)
                    Haptics.shared.play(.generation)
                } else {
                try await client.stream(profile: requestProfile, key: key, messages: context) { [weak self] delta in
                    guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                    self.updateMessage(chatID: chatID, messageID: assistant.id) {
                        $0.content += delta.text
                        $0.reasoning += delta.reasoning
                        if let usage = delta.usage {
                            var combined = $0.tokenUsage ?? TokenUsage()
                            combined.merge(usage)
                            $0.tokenUsage = combined
                        }
                    }
                    run.generatedBytes += delta.text.utf8.count + delta.reasoning.utf8.count
                    if !delta.text.isEmpty || !delta.reasoning.isEmpty { Haptics.shared.play(.generation, scale: 0.35) }
                    run.estimatedOutput = (run.generatedBytes + 3) / 4
                    self.refreshActivity(run)
                    if Date().timeIntervalSince(run.lastCheckpoint) >= (self.isInBackground ? 2 : 10) {
                        self.checkpointGeneration()
                    }
                }
                }
                guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                self.updateMessage(chatID: chatID, messageID: assistant.id) { $0.status = .complete }
                Haptics.shared.play(.generation)
            } catch {
                guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                let wasCancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                let detail = error.localizedDescription.replacingOccurrences(of: key, with: "[Key]")
                self.updateMessage(chatID: chatID, messageID: assistant.id) {
                    $0.status = wasCancelled ? .stopped : .failed
                    $0.error = wasCancelled ? nil : detail
                }
                Haptics.shared.play(.generation)
            }
            guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
            let message = self.conversations.first(where: { $0.id == chatID })?.messages.first(where: { $0.id == assistant.id })
            self.runs[chatID] = nil
            self.generationTasks.finish(conversationID: chatID, runID: token)
            self.finishGeneration(run, status: message?.status == .complete ? "回复已完成" : "回复已中断")
            self.persist()
        }
    }

    func setImageSettings(_ settings: ImageGenerationSettings) {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }), profiles[index].imageSettings != settings else { return }
        profiles[index].imageSettings = settings
        persist()
    }

    private func reply(for run: ReplyRun) -> ChatMessage? {
        conversations.first(where: { $0.id == run.chatID })?.messages.first(where: { $0.id == run.messageID })
    }

    private func tokenDisplay(_ message: ChatMessage, run: ReplyRun, final: Bool = false) -> (Int, Bool) {
        if let usage = message.tokenUsage, usage.isReported {
            let live = (usage.input ?? 0) + run.estimatedOutput
            let authoritative = final && message.status == .complete && (usage.output != nil || usage.total != nil)
            return authoritative ? (usage.totalTokens, false) : (max(usage.totalTokens, live), live > usage.totalTokens)
        }
        return (run.estimatedOutput, true)
    }

    private func refreshActivity(_ run: ReplyRun, force: Bool = false) {
        guard let reply = reply(for: run) else { return }
        let (tokens, estimated) = tokenDisplay(reply, run: run)
        backgroundServices.updateActivity(replyID: run.messageID, status: run.phase ?? (isInBackground ? "正在后台回复" : "正在接收回复"),
                                            tokens: tokens, estimated: estimated, receivedBytes: run.generatedBytes, force: force)
    }

    private func checkpointGeneration() {
        for run in runs.values {
            guard let reply = reply(for: run) else { continue }
            updateMessage(chatID: run.chatID, messageID: reply.id) { $0.elapsedSeconds = Date().timeIntervalSince($0.createdAt) }
            recordUsage(reply, run: run)
            run.lastCheckpoint = Date()
        }
        persist()
    }

    private func recordUsage(_ reply: ChatMessage, run: ReplyRun) {
        let record = UsageRecord(id: reply.id, profileID: run.profileID, model: reply.model ?? "",
                                 date: reply.createdAt, usage: reply.tokenUsage, estimatedOutput: run.estimatedOutput,
                                 usageIsFinal: reply.status == .complete && (reply.tokenUsage?.output != nil || reply.tokenUsage?.total != nil))
        if let i = usageRecords.firstIndex(where: { $0.id == record.id }) { usageRecords[i] = record }
        else { usageRecords.append(record) }
    }

    private func finishGeneration(_ run: ReplyRun, status: String) {
        guard let reply = reply(for: run) else {
            // Resource cleanup must not depend on the message still being present.
            backgroundServices.endReply(modelName: "生成回复", status: status, tokens: run.estimatedOutput,
                estimated: true, replyID: run.messageID, conversationID: run.chatID)
            return
        }
        updateMessage(chatID: run.chatID, messageID: run.messageID) { $0.elapsedSeconds = Date().timeIntervalSince($0.createdAt) }
        recordUsage(reply, run: run)
        let (tokens, estimated) = tokenDisplay(reply, run: run, final: true)
        backgroundServices.endReply(modelName: reply.modelDisplayTitle, status: status, tokens: tokens,
                                    estimated: estimated, replyID: reply.id, conversationID: run.chatID)
    }

    func saveBalanceConfiguration(_ configuration: BalanceConfiguration, for profile: APIProfile) throws {
        guard (0...1440).contains(configuration.refreshMinutes) else { throw APIError.provider("刷新间隔应为 0–1440 分钟，0 表示仅手动刷新。") }
        if !configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let base = URL(string: profile.baseURL) else { throw APIError.invalidURL }
            _ = try BalanceJSON.endpoint(configuration.endpoint, relativeTo: base)
        }
        balanceConfigurations[profile.id] = configuration
        balances[profile.id] = nil
        persist()
    }

    func refreshBalance(_ profile: APIProfile) async {
        guard balances[profile.id]?.isLoading != true,
              let configuration = balanceConfigurations[profile.id], !configuration.endpoint.isEmpty else { return }
        var state = balances[profile.id] ?? BalanceState()
        state.isLoading = true; state.error = nil; state.lastAttempt = Date()
        balances[profile.id] = state
        var key = ""
        do {
            key = try readKey(for: profile)
            let value = try await client.fetchBalance(profile: profile, key: key, configuration: configuration)
            guard profiles.contains(where: { $0.id == profile.id }), balanceConfigurations[profile.id] == configuration else { return }
            state.value = value; state.updatedAt = Date()
        } catch {
            if Task.isCancelled {
                state.isLoading = false; state.lastAttempt = nil
                balances[profile.id] = state
                return
            }
            state.error = key.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: key, with: "[Key]")
        }
        state.isLoading = false
        if profiles.contains(where: { $0.id == profile.id }), balanceConfigurations[profile.id] == configuration {
            balances[profile.id] = state
        }
    }

    private func refreshDueBalances() async {
        for profile in profiles {
            guard !Task.isCancelled, !isInBackground else { return }
            guard let config = balanceConfigurations[profile.id], !config.endpoint.isEmpty, config.refreshMinutes > 0 else { continue }
            let last = balances[profile.id]?.lastAttempt ?? .distantPast
            if Date().timeIntervalSince(last) >= Double(config.refreshMinutes) * 60 { await refreshBalance(profile) }
        }
    }

    private func updateMessage(chatID: UUID, messageID: UUID, mutation: (inout ChatMessage) -> Void) {
        guard let i = conversations.firstIndex(where: { $0.id == chatID }),
              let j = conversations[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        mutation(&conversations[i].messages[j])
    }
}

@MainActor
private final class ReplyRun {
    let id = UUID()
    let chatID: UUID
    let messageID: UUID
    let profileID: UUID
    var lastCheckpoint = Date()
    var estimatedOutput = 0
    var generatedBytes = 0
    var phase: String?
    init(chatID: UUID, messageID: UUID, profileID: UUID) {
        self.chatID = chatID; self.messageID = messageID; self.profileID = profileID
    }
}

struct BalanceState {
    var value: String?
    var updatedAt: Date?
    var lastAttempt: Date?
    var error: String?
    var isLoading = false
}
