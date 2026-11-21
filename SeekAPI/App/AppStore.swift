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
    private var searchProviderIDsByProfile: [UUID: UUID] = [:]
    private var searchAllowed = UserDefaults.standard.bool(forKey: "search.enabled") {
        didSet { UserDefaults.standard.set(searchAllowed, forKey: "search.enabled") }
    }
    var searchEnabled: Bool {
        get { searchAllowed && selectedSearchProviderID != nil }
        set {
            searchAllowed = newValue
            if newValue, searchProviderIDsByProfile[selectedProfileID] == nil, let id = selectedSearchProviderID {
                selectSearchProvider(id)
            }
        }
    }
    var selectedSearchProviderID: UUID? {
        if let remembered = searchProviderIDsByProfile[selectedProfileID], isAvailableSearchProvider(remembered) {
            return remembered
        }
        return searchProviders.first?.id
    }
    var selectedSearchProvider: SearchProvider? {
        let id = selectedSearchProviderID
        if id == SearchProvider.deepSeekHosted.id { return .deepSeekHosted }
        return searchProviders.first { $0.id == id }
    }
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
                searchProviderIDsByProfile = state.searchProviderIDsByProfile ?? [:]
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
                if state.searchProviderIDsByProfile == nil, let previous = state.selectedSearchProviderID,
                   isAvailableSearchProvider(previous) {
                    restoreLegacySearchProvider(previous)
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
        persist()
    }

    private func isAvailableSearchProvider(_ id: UUID) -> Bool {
        id == SearchProvider.deepSeekHosted.id || searchProviders.contains { $0.id == id }
    }

    private func restoreLegacySearchProvider(_ id: UUID) {
        guard id == SearchProvider.deepSeekHosted.id else {
            searchProviderIDsByProfile[selectedProfileID] = id
            return
        }
        // A formerly global hosted selection may have been saved while another supplier was active.
        let compatible = profiles.filter { profile in
            profile.models.contains { model in
                var candidate = profile
                candidate.selectModel(model.id)
                return WebSearch.supportsDeepSeekHosted(candidate)
            }
        }
        if let supplier = compatible.first(where: { $0.id == selectedProfileID })
            ?? (compatible.count == 1 ? compatible.first : nil) {
            searchProviderIDsByProfile[supplier.id] = id
        }
    }

    func selectSearchProvider(_ id: UUID) {
        guard isAvailableSearchProvider(id),
              id != SearchProvider.deepSeekHosted.id || WebSearch.supportsDeepSeekHosted(selectedProfile) else { return }
        searchProviderIDsByProfile[selectedProfileID] = id
        persist()
    }
    func deleteSearchProvider(_ provider: SearchProvider) throws {
        guard !hasActiveGenerations else { return }
        try searchKeychain.delete(for: provider.id)
        searchProviders.removeAll { $0.id == provider.id }
        searchProviderIDsByProfile = searchProviderIDsByProfile.filter { $0.value != provider.id }
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
        searchProviderIDsByProfile.removeValue(forKey: profile.id)
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
        let searchProvider: SearchProvider?
        do {
            try RequestBuilder.validate(selectedProfile)
            guard !(try readKey(for: selectedProfile)).isEmpty else { throw APIError.missingKey }
            if selectedProfile.selectedModel.effectiveType == .imageGeneration {
                try ImageGenerationAPI.validateReferences(attachments)
                try selectedProfile.imageSettings.validate(provider: selectedProfile.provider)
            }
            searchProvider = try searchProviderForReply(selectedProfile)
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
        startGeneration(searchProvider: searchProvider)
        return true
    }

    func regenerate() {
        guard !isStreaming, let index = currentIndex,
              conversations[index].messages.last?.role == .assistant else { return }
        let searchProvider: SearchProvider?
        do {
            try RequestBuilder.validate(selectedProfile)
            guard !(try readKey(for: selectedProfile)).isEmpty else { throw APIError.missingKey }
            searchProvider = try searchProviderForReply(selectedProfile)
        } catch { notice = error.localizedDescription; return }
        let discarded = conversations[index].messages.removeLast().attachments ?? []
        let retained = Set(conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id))
        let removable = discarded.filter { !retained.contains($0.id) }
        if !removable.isEmpty { Task { await AttachmentStore.shared.remove(removable) } }
        startGeneration(searchProvider: searchProvider)
    }

    private func searchProviderForReply(_ profile: APIProfile) throws -> SearchProvider? {
        guard searchEnabled, profile.selectedModel.effectiveType != .imageGeneration,
              let provider = selectedSearchProvider else { return nil }
        if provider.kind == .deepSeekHosted, !WebSearch.supportsDeepSeekHosted(profile) {
            throw APIError.provider("DeepSeek 托管搜索需要使用官方 API 的 deepseek-flash。请切换模型、选择其他搜索服务或关闭联网搜索。")
        }
        return provider
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
                                             searchProviders: searchProviders, selectedSearchProviderID: selectedSearchProviderID,
                                             searchProviderIDsByProfile: searchProviderIDsByProfile))
            return true
        } catch { notice = "本地保存失败：\(error.localizedDescription)"; return false }
    }

    private var currentIndex: Int? { conversations.firstIndex { $0.id == selectedConversationID } }

    private func startGeneration(searchProvider: SearchProvider?) {
        guard let index = currentIndex else { return }
        let profile = selectedProfile
        let key: String
        do { key = try readKey(for: profile) }
        catch { notice = error.localizedDescription; persist(); return }
        conversations[index].profileID = profile.id
        conversations[index].modelID = profile.selectedModelID
        let context = conversations[index].messages
        let isImageGeneration = profile.selectedModel.effectiveType == .imageGeneration
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
        if isImageGeneration { run.phase = "正在生成图像" }
        runs[chatID] = run
        backgroundServices.beginReply(attributes: ReplyActivityAttributes(replyID: assistant.id, conversationID: chatID,
            modelName: String(assistant.modelDisplayTitle.prefix(120)),
            supplierLogo: ModelLogo.brandName(model: profile.model, provider: profile.provider, iconStyle: profile.selectedModel.iconStyle), startedAt: assistant.createdAt))
        persist()

        generationTasks.start(conversationID: chatID, runID: run.id) { [weak self, client] token in
            do {
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
                    guard let self else { return }
                    try await self.streamReply(profile: profile, key: key, context: context,
                                               searchProvider: searchProvider, run: run)
                }
                guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                self.updateMessage(chatID: chatID, messageID: assistant.id) {
                    $0.status = .complete
                    $0.generationStage = nil
                }
                Haptics.shared.play(.generation)
            } catch {
                guard let self, self.generationTasks.isCurrent(conversationID: chatID, runID: token) else { return }
                let wasCancelled = Task.isCancelled || (error as? URLError)?.code == .cancelled
                let detail = error.localizedDescription.replacingOccurrences(of: key, with: "[Key]")
                self.updateMessage(chatID: chatID, messageID: assistant.id) {
                    $0.status = wasCancelled ? .stopped : .failed
                    $0.error = wasCancelled ? nil : detail
                    $0.generationStage = nil
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

    private func streamReply(profile: APIProfile, key: String, context: [ChatMessage],
                             searchProvider: SearchProvider?, run: ReplyRun) async throws {
        let usesIndependentSearch = searchProvider.map { $0.kind != .deepSeekHosted } ?? false
        var requestProfile = profile
        if let searchProvider {
            requestProfile.systemPrompt += searchProvider.kind == .deepSeekHosted
                ? ChatSearchSession.evidenceInstructions : ChatSearchSession.instructions
        }

        func stream(_ tools: ChatWebTools, _ turns: [ChatToolTurn]) async throws -> ChatToolResponse {
            let response = try await client.stream(profile: requestProfile, key: key, messages: context,
                                                   webTools: tools, toolTurns: turns) { [weak self] delta in
                self?.receive(delta, searchProvider: searchProvider, run: run)
            }
            run.completedUsage.addRequest(run.currentUsage)
            run.currentUsage = TokenUsage()
            try Task.checkCancellation()
            if usesIndependentSearch, !response.calls.isEmpty,
               generationTasks.isCurrent(conversationID: run.chatID, runID: run.id) {
                updateMessage(chatID: run.chatID, messageID: run.messageID) { $0.content = "" }
            }
            return response
        }

        if usesIndependentSearch, let searchProvider {
            // Keep the key available if the device locks before the model requests a search.
            var searchKey = try? readSearchKey(searchProvider)
            run.sources = try await ChatSearchSession.run(stream: stream, lookup: { query in
                if searchKey == nil { searchKey = try self.readSearchKey(searchProvider) }
                return try await self.searchClient.search(provider: searchProvider, key: searchKey ?? "", query: query)
            }, onProgress: { progress in
                guard self.generationTasks.isCurrent(conversationID: run.chatID, runID: run.id) else { return }
                switch progress {
                case .searching(let queries):
                    self.showSearchProgress(searchProvider, queries: queries, run: run)
                case .searched(let sources, let failed):
                    self.showSearchResults(sources, failed: failed, run: run)
                }
            })
        } else {
            let tools: ChatWebTools = searchProvider == nil ? .none : .deepSeekHosted
            let response = try await stream(tools, [])
            guard response.calls.isEmpty else { throw APIError.malformedResponse }
            if tools == .deepSeekHosted, let history = response.hostedHistoryJSON,
               generationTasks.isCurrent(conversationID: run.chatID, runID: run.id) {
                updateMessage(chatID: run.chatID, messageID: run.messageID) { $0.hostedSearchHistory = history }
            }
        }

        guard generationTasks.isCurrent(conversationID: run.chatID, runID: run.id) else { return }
        if run.didSearch || !run.hostedCitations.isEmpty {
            let content = conversations.first { $0.id == run.chatID }?.messages.first { $0.id == run.messageID }?.content ?? ""
            let cited = usesIndependentSearch ? run.sources.linkingReferences(in: content)
                : run.sources.linking(run.hostedCitations, in: content)
            updateMessage(chatID: run.chatID, messageID: run.messageID) {
                $0.content = cited
                $0.searchSources = run.sources.displayItems
                $0.searchProviderName = searchProvider?.name
                if run.searchFailed || !run.pendingHostedSearches.isEmpty {
                    $0.error = run.sources.items.isEmpty ? "联网搜索失败，本次回复未取得网页来源。请检查搜索服务设置或网络连接。"
                        : "部分搜索失败，回复仅能参考已取得的来源。"
                } else if run.sources.items.isEmpty {
                    $0.error = "联网搜索未找到可用来源。"
                }
            }
        }
    }

    private func receive(_ delta: ReplyDelta, searchProvider: SearchProvider?, run: ReplyRun) {
        guard generationTasks.isCurrent(conversationID: run.chatID, runID: run.id) else { return }
        run.currentUsage.merge(delta.usage)
        var totalUsage = run.completedUsage
        totalUsage.addRequest(run.currentUsage)
        updateMessage(chatID: run.chatID, messageID: run.messageID) {
            $0.content += delta.text
            $0.reasoning += delta.reasoning
            if totalUsage.isReported { $0.tokenUsage = totalUsage }
        }
        if let searchProvider, searchProvider.kind == .deepSeekHosted {
            run.hostedCitations.append(contentsOf: delta.hostedCitations)
            for event in delta.hostedSearchEvents {
                switch event {
                case .started(let id, let queries):
                    run.pendingHostedSearches[id] = queries
                    showSearchProgress(searchProvider, queries: queries, run: run)
                case .finished(let id, let sources, let failed):
                    run.pendingHostedSearches.removeValue(forKey: id)
                    run.sources.add(sources)
                    showSearchResults(run.sources.displayItems, failed: failed, run: run)
                    if let next = run.pendingHostedSearches.values.first {
                        showSearchProgress(searchProvider, queries: next, run: run)
                    }
                }
            }
        }
        run.generatedBytes += delta.text.utf8.count + delta.reasoning.utf8.count
        if !delta.text.isEmpty || !delta.reasoning.isEmpty { Haptics.shared.play(.generation, scale: 0.35) }
        run.estimatedOutput = (run.generatedBytes + 3) / 4
        refreshActivity(run)
        if Date().timeIntervalSince(run.lastCheckpoint) >= (isInBackground ? 2 : 10) { checkpointGeneration() }
    }

    private func showSearchProgress(_ provider: SearchProvider, queries: [String], run: ReplyRun) {
        run.didSearch = true
        run.phase = "正在联网搜索"
        let display = String(queries.joined(separator: "、").prefix(160))
        updateMessage(chatID: run.chatID, messageID: run.messageID) {
            $0.searchProviderName = provider.name
            $0.generationStage = display.isEmpty ? "正在联网搜索…" : "正在联网搜索：\(display)"
        }
        refreshActivity(run, force: true)
    }

    private func showSearchResults(_ sources: [SearchResult], failed: Bool, run: ReplyRun) {
        run.didSearch = true
        run.searchFailed = run.searchFailed || failed
        run.phase = nil
        updateMessage(chatID: run.chatID, messageID: run.messageID) {
            $0.searchSources = sources
            if failed {
                $0.generationStage = "搜索遇到问题，正在继续生成…"
            } else {
                $0.generationStage = sources.isEmpty ? "未找到可用来源，正在继续生成…" : "已检索 \(sources.count) 条资料，正在继续生成…"
            }
        }
        refreshActivity(run, force: true)
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
    var currentUsage = TokenUsage()
    var completedUsage = TokenUsage()
    var sources = ChatSearchSources()
    var hostedCitations: [HostedSearchCitation] = []
    var pendingHostedSearches: [String: [String]] = [:]
    var didSearch = false
    var searchFailed = false
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
