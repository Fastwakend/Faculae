import Foundation

/// Model settings belong to the model; connection details and credentials belong
/// to the containing supplier. The keychain continues to use APIProfile.id.
public struct APIModel: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var model: String
    public var displayName: String?
    public var systemPrompt: String
    public var temperature: Double
    public var sendsTemperature: Bool
    public var maxOutputTokens: Int
    public var reasoningLevel: ReasoningLevel?
    public var iconStyle: ModelIconStyle?
    public var customIconID: UUID?
    public var modelType: ModelType?
    public var imageGenerationSettings: ImageGenerationSettings?
    public var effectiveType: ModelType { modelType ?? .chat }

    public init(id: UUID = UUID(), model: String, systemPrompt: String = "",
                temperature: Double = 0.7, sendsTemperature: Bool = false,
                maxOutputTokens: Int = 4096, reasoningLevel: ReasoningLevel? = nil,
                iconStyle: ModelIconStyle? = nil, customIconID: UUID? = nil,
                displayName: String? = nil) {
        self.id = id
        self.model = model
        self.displayName = displayName
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.sendsTemperature = sendsTemperature
        self.maxOutputTokens = maxOutputTokens
        self.reasoningLevel = reasoningLevel
        self.iconStyle = iconStyle
        self.customIconID = customIconID
    }

    public var displayTitle: String {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? model : name
    }
}

public enum ModelSettingsError: LocalizedError {
    case duplicateModel, lastModel, modelNotFound
    public var errorDescription: String? {
        switch self {
        case .duplicateModel: "这个供应商已添加相同的模型 ID。"
        case .lastModel: "每个供应商至少需要保留一个模型。"
        case .modelNotFound: "这个模型已不存在，请重新选择。"
        }
    }
}

public struct APIProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var provider: APIProvider
    public var baseURL: String
    public private(set) var models: [APIModel]
    public private(set) var selectedModelID: UUID

    public var selectedModel: APIModel { models[selectedModelIndex] }
    private var selectedModelIndex: Int { models.firstIndex { $0.id == selectedModelID } ?? 0 }

    // Existing request/reasoning code always sees the selected model's settings.
    public var model: String {
        get { selectedModel.model }
        set { models[selectedModelIndex].model = newValue }
    }
    public var systemPrompt: String {
        get { selectedModel.systemPrompt }
        set { models[selectedModelIndex].systemPrompt = newValue }
    }
    public var temperature: Double {
        get { selectedModel.temperature }
        set { models[selectedModelIndex].temperature = newValue }
    }
    public var sendsTemperature: Bool {
        get { selectedModel.sendsTemperature }
        set { models[selectedModelIndex].sendsTemperature = newValue }
    }
    public var maxOutputTokens: Int {
        get { selectedModel.maxOutputTokens }
        set { models[selectedModelIndex].maxOutputTokens = newValue }
    }
    public var reasoningLevel: ReasoningLevel? {
        get { selectedModel.reasoningLevel }
        set { models[selectedModelIndex].reasoningLevel = newValue }
    }
    public var imageSettings: ImageGenerationSettings {
        get { selectedModel.imageGenerationSettings ?? ImageGenerationSettings() }
        set { models[selectedModelIndex].imageGenerationSettings = newValue }
    }

    public init(id: UUID = UUID(), name: String, provider: APIProvider,
                baseURL: String? = nil, model: String? = nil, systemPrompt: String = "",
                temperature: Double = 0.7, sendsTemperature: Bool = false, maxOutputTokens: Int = 4096,
                reasoningLevel: ReasoningLevel? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        let entry = APIModel(model: model ?? provider.defaultModel, systemPrompt: systemPrompt,
                             temperature: temperature, sendsTemperature: sendsTemperature,
                             maxOutputTokens: maxOutputTokens, reasoningLevel: reasoningLevel)
        models = [entry]
        selectedModelID = entry.id
    }

    public func containsModel(_ model: String) -> Bool {
        models.contains { canonicalModelID($0.model) == canonicalModelID(model) }
    }

    @discardableResult
    public mutating func addModel(_ model: String) throws -> UUID {
        let value = canonicalModelID(model)
        guard !value.isEmpty else { throw APIError.invalidModel }
        guard !containsModel(value) else { throw ModelSettingsError.duplicateModel }
        let entry = APIModel(model: value)
        models.append(entry)
        return entry.id
    }

    public mutating func updateModel(_ model: APIModel) throws {
        guard let index = models.firstIndex(where: { $0.id == model.id }) else { throw ModelSettingsError.modelNotFound }
        var entry = model
        entry.model = canonicalModelID(entry.model)
        entry.displayName = entry.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if entry.displayName?.isEmpty == true { entry.displayName = nil }
        guard !entry.model.isEmpty else { throw APIError.invalidModel }
        guard !models.contains(where: { $0.id != entry.id && canonicalModelID($0.model) == entry.model }) else {
            throw ModelSettingsError.duplicateModel
        }
        models[index] = entry
    }

    public mutating func removeModel(_ id: UUID) throws {
        guard models.contains(where: { $0.id == id }) else { throw ModelSettingsError.modelNotFound }
        guard models.count > 1 else { throw ModelSettingsError.lastModel }
        models.removeAll { $0.id == id }
        if selectedModelID == id { selectedModelID = models[0].id }
    }

    @discardableResult
    public mutating func moveModels(fromOffsets source: IndexSet, toOffset destination: Int) -> Bool {
        ListOrdering.move(&models, fromOffsets: source, toOffset: destination)
    }

    @discardableResult
    public mutating func selectModel(_ id: UUID) -> Bool {
        guard models.contains(where: { $0.id == id }) else { return false }
        selectedModelID = id
        return true
    }

    @discardableResult
    public mutating func restoreModel(for conversation: Conversation) -> Bool {
        guard conversation.profileID == id else { return false }
        if let modelID = conversation.modelID, selectModel(modelID) { return true }
        // Earlier conversations only recorded the API model name on replies.
        if let lastModel = conversation.messages.last(where: { $0.role == .assistant && $0.model != nil })?.model,
           let entry = models.first(where: { canonicalModelID($0.model) == canonicalModelID(lastModel) }) {
            return selectModel(entry.id)
        }
        return false
    }

    private func canonicalModelID(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return provider == .gemini && value.hasPrefix("models/") ? String(value.dropFirst(7)) : value
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, models, selectedModelID
        case model, systemPrompt, temperature, sendsTemperature, maxOutputTokens, reasoningLevel
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        provider = try values.decode(APIProvider.self, forKey: .provider)
        baseURL = try values.decode(String.self, forKey: .baseURL)
        if let entries = try values.decodeIfPresent([APIModel].self, forKey: .models) {
            guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count else {
                throw DecodingError.dataCorruptedError(forKey: .models, in: values, debugDescription: "Invalid model collection")
            }
            models = entries
            let saved = try values.decodeIfPresent(UUID.self, forKey: .selectedModelID)
            selectedModelID = entries.first(where: { $0.id == saved })?.id ?? entries[0].id
        } else {
            let entry = APIModel(model: try values.decode(String.self, forKey: .model),
                                 systemPrompt: try values.decodeIfPresent(String.self, forKey: .systemPrompt) ?? "",
                                 temperature: try values.decodeIfPresent(Double.self, forKey: .temperature) ?? 0.7,
                                 sendsTemperature: try values.decodeIfPresent(Bool.self, forKey: .sendsTemperature) ?? false,
                                 maxOutputTokens: try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? 4096,
                                 reasoningLevel: try values.decodeIfPresent(ReasoningLevel.self, forKey: .reasoningLevel))
            models = [entry]
            selectedModelID = entry.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encode(provider, forKey: .provider)
        try values.encode(baseURL, forKey: .baseURL)
        try values.encode(models, forKey: .models)
        try values.encode(selectedModelID, forKey: .selectedModelID)
    }

    public static var presets: [APIProfile] {
        [APIProfile(name: "DeepSeek", provider: .openAI, baseURL: "https://api.deepseek.com", model: "deepseek-chat"),
         APIProfile(name: "OpenAI", provider: .openAI),
         APIProfile(name: "Gemini", provider: .gemini),
         APIProfile(name: "Claude", provider: .claude)]
    }
}
