import Foundation

public enum APIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, gemini, claude
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .openAI: return "OpenAI 兼容"
        case .gemini: return "Gemini"
        case .claude: return "Claude"
        }
    }
    public var defaultBaseURL: String {
        switch self {
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .claude: return "https://api.anthropic.com/v1"
        }
    }
    public var defaultModel: String {
        switch self {
        case .openAI: return "gpt-4.1-mini"
        case .gemini: return "gemini-2.5-flash"
        case .claude: return "claude-sonnet-4-5"
        }
    }
}

public struct ChatAttachment: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case image, pdf, text }
    public var id: UUID
    public var name: String
    public var mimeType: String
    public var kind: Kind
    public var byteCount: Int
    public init(id: UUID = UUID(), name: String, mimeType: String, kind: Kind, byteCount: Int) {
        self.id = id; self.name = name; self.mimeType = mimeType; self.kind = kind; self.byteCount = byteCount
    }
}

public enum MessageRole: String, Codable, Sendable { case user, assistant }
public enum MessageStatus: String, Codable, Sendable { case complete, streaming, stopped, failed }

public struct ChatMessage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoning: String
    public var status: MessageStatus
    public var model: String?
    public var error: String?
    public var createdAt: Date
    public var attachments: [ChatAttachment]?
    public var modelProvider: APIProvider?
    public var modelIconStyle: ModelIconStyle?
    public var customIconID: UUID?
    public var tokenUsage: TokenUsage?
    public var elapsedSeconds: Double?
    public var modelDisplayName: String?
    public var searchSources: [SearchResult]?
    public var searchProviderName: String?
    public var generationStage: String?
    public var imageGenerationSettings: ImageGenerationSettings?

    public init(id: UUID = UUID(), role: MessageRole, content: String = "", reasoning: String = "",
                status: MessageStatus = .complete, model: String? = nil, error: String? = nil,
                createdAt: Date = Date(), attachments: [ChatAttachment]? = nil,
                modelProvider: APIProvider? = nil, modelIconStyle: ModelIconStyle? = nil,
                customIconID: UUID? = nil, modelDisplayName: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.status = status
        self.model = model
        self.error = error
        self.createdAt = createdAt
        self.attachments = attachments
        self.modelProvider = modelProvider
        self.modelIconStyle = modelIconStyle
        self.customIconID = customIconID
        self.modelDisplayName = modelDisplayName
    }

    public var modelDisplayTitle: String {
        let name = modelDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? (model ?? "助手") : name
    }

    public var isValidContext: Bool {
        (!content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(attachments ?? []).isEmpty) &&
        (role == .user || status == .complete || status == .stopped)
    }
}

public struct Conversation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var profileID: UUID
    public var modelID: UUID?
    public var messages: [ChatMessage]
    public var updatedAt: Date
    public var isPinned: Bool
    public var parentConversationID: UUID?
    public var parentMessageID: UUID?

    public init(id: UUID = UUID(), title: String = "新对话", profileID: UUID,
                messages: [ChatMessage] = [], updatedAt: Date = Date(), isPinned: Bool = false,
                modelID: UUID? = nil) {
        self.id = id
        self.title = title
        self.profileID = profileID
        self.modelID = modelID
        self.messages = messages
        self.updatedAt = updatedAt
        self.isPinned = isPinned
    }

    public var markdown: String {
        (["# \(title)"] + messages.map { message in
            "## \(message.role == .user ? "你" : "助手")\n\n" + message.content +
                (message.attachments ?? []).map { "\n\n[附件：\($0.name)]" }.joined()
        }).joined(separator: "\n\n")
    }
}

public struct ReplyDelta: Equatable, Sendable {
    public var text: String
    public var reasoning: String
    public var isFinished: Bool
    public var usage: TokenUsage?
    public init(text: String = "", reasoning: String = "", isFinished: Bool = false, usage: TokenUsage? = nil) {
        self.text = text
        self.reasoning = reasoning
        self.isFinished = isFinished
        self.usage = usage
    }
}

public enum APIError: Error, LocalizedError, Equatable, Sendable {
    case invalidURL, invalidModel, missingKey, invalidParameters, malformedResponse, emptyReply
    case http(Int, String)
    case provider(String)
    case streamTooLarge

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "请输入有效的 HTTPS API 地址，地址中不要包含 Key、查询参数或片段。"
        case .invalidModel: return "请输入有效的模型 ID。Gemini 模型名不能包含路径或查询参数。"
        case .missingKey: return "请先在 API 设置中保存这个服务的 API Key。"
        case .invalidParameters: return "最大输出须为 1–131072，温度须为 0–1。"
        case .malformedResponse: return "服务返回了无法解析的数据，请检查协议类型和 API 地址。"
        case .emptyReply: return "服务未返回可显示的内容，请检查模型权限、输出上限后重试。"
        case .http(let status, let detail): return "HTTP \(status)：\(detail)"
        case .provider(let detail): return detail
        case .streamTooLarge: return "单个流事件过大，已停止接收。"
        }
    }
}
