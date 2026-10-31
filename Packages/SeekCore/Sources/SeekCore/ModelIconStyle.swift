import Foundation

public enum ModelIconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, openAI, deepSeek, claude, gemini, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动识别"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .custom: "自定义图片"
        }
    }
}
