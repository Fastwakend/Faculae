import Foundation

public enum ModelFamily: String, Codable, Sendable {
    case openAI, deepSeek, claude, gemini

    public var title: String {
        switch self { case .openAI: "OpenAI"; case .deepSeek: "DeepSeek"; case .claude: "Claude"; case .gemini: "Gemini" }
    }

    public var reasoningLevels: [ReasoningLevel] {
        switch self {
        case .openAI, .claude: return [.low, .medium, .high, .xhigh, .max]
        case .deepSeek: return [.off, .low, .high, .max]
        case .gemini: return [.low, .medium, .high]
        }
    }
}

public enum ReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    // Retained only for reading 1.2 and earlier settings; no automatic stop in the UI.
    case automatic, off, low, medium, high, xhigh, max
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自动"
        case .off: "Off"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Xhigh"
        case .max: "Max"
        }
    }
}

public enum ReasoningControl: Equatable, Sendable {
    case effort, deepSeek, geminiBudget, geminiLevel, claudeBudget, claudeAdaptive
}

extension APIProfile {
    public var modelFamily: ModelFamily {
        let name = model.lowercased()
        if name.contains("deepseek") { return .deepSeek }
        if name.contains("claude") { return .claude }
        if name.contains("gemini") { return .gemini }
        if name.contains("gpt") || ["o1", "o3", "o4"].contains(where: name.hasPrefix) { return .openAI }
        switch provider { case .openAI: return .openAI; case .gemini: return .gemini; case .claude: return .claude }
    }

    public var availableReasoningLevels: [ReasoningLevel] { modelFamily.reasoningLevels }

    /// A legacy automatic value stays unset until the user selects a stop.
    public var explicitReasoningLevel: ReasoningLevel? {
        guard let reasoningLevel, reasoningLevel != .automatic else { return nil }
        return normalizedReasoningLevel(reasoningLevel)
    }

    public var sliderReasoningLevel: ReasoningLevel {
        if let explicitReasoningLevel { return explicitReasoningLevel }
        return modelFamily == .deepSeek ? (model.lowercased().contains("reasoner") ? .high : .off) : .low
    }

    public func normalizedReasoningLevel(_ level: ReasoningLevel) -> ReasoningLevel {
        if availableReasoningLevels.contains(level) { return level }
        switch level {
        case .xhigh, .max: return .high // e.g. switching a profile to Gemini
        case .medium: return .high // DeepSeek has no Medium stop
        case .automatic: return modelFamily == .deepSeek ? .off : .low
        case .off: return .low
        case .low, .high: return level
        }
    }

    public var reasoningControl: ReasoningControl {
        let name = model.lowercased().replacingOccurrences(of: "models/", with: "")
        if modelFamily == .deepSeek { return .deepSeek }
        switch provider {
        case .openAI: return .effort
        case .gemini: return name.hasPrefix("gemini-2") ? .geminiBudget : .geminiLevel
        case .claude:
            let tokens = name.components(separatedBy: CharacterSet(charactersIn: "-./"))
            let numbers = tokens.compactMap { $0.count <= 2 ? Int($0) : nil }
            let major = numbers.first ?? 5
            let minor = numbers.dropFirst().first ?? 0
            return major > 4 || (major == 4 && minor >= 6) ? .claudeAdaptive : .claudeBudget
        }
    }

    public var reasoningBudget: Int {
        guard let level = explicitReasoningLevel else { return -1 }
        let cap = min(modelFamily == .claude ? 32768 : 8192, maxOutputTokens - 1)
        if modelFamily == .claude {
            // Keep all five manual-budget stops distinct within the user's output cap.
            let position = [.low, .medium, .high, .xhigh, .max].firstIndex(of: level) ?? 0
            return 1024 + max(0, cap - 1024) * position / 4
        }
        switch level {
        case .low: return min(1024, cap)
        case .medium: return min(4096, max(1024, maxOutputTokens / 2))
        case .high, .xhigh, .max: return cap
        case .off: return 0
        case .automatic: return -1
        }
    }
}
