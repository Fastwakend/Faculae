import Foundation

/// Providers report cumulative counters. Merge snapshots, never add chunks.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var total: Int?
    public var cachedInput: Int?
    public var reasoning: Int?
    public init(input: Int? = nil, output: Int? = nil, total: Int? = nil,
                cachedInput: Int? = nil, reasoning: Int? = nil) {
        self.input = input; self.output = output; self.total = total
        self.cachedInput = cachedInput; self.reasoning = reasoning
    }
    public var totalTokens: Int { total ?? ((input ?? 0) + (output ?? 0)) }
    public var isReported: Bool { input != nil || output != nil || total != nil }
    public mutating func merge(_ other: TokenUsage?) {
        guard let other else { return }
        func counter(_ old: Int?, _ new: Int?) -> Int? {
            guard let new else { return old }; return max(old ?? 0, max(0, new))
        }
        input = counter(input, other.input); output = counter(output, other.output)
        total = counter(total, other.total); cachedInput = counter(cachedInput, other.cachedInput)
        reasoning = counter(reasoning, other.reasoning)
    }
    public static func decode(_ json: [String: Any], provider: APIProvider) -> TokenUsage? {
        let message = json["message"] as? [String: Any]
        guard let u = (json["usage"] ?? json["usageMetadata"] ?? message?["usage"]) as? [String: Any] else { return nil }
        func n(_ name: String, in object: [String: Any]? = nil) -> Int? {
            guard let value = (object ?? u)[name] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
                  value.doubleValue >= 0, value.doubleValue <= 1_000_000_000,
                  value.doubleValue.rounded() == value.doubleValue else { return nil }
            return value.intValue
        }
        let result: TokenUsage
        switch provider {
        case .openAI:
            result = TokenUsage(input: n("prompt_tokens"), output: n("completion_tokens"), total: n("total_tokens"),
                cachedInput: n("cached_tokens", in: u["prompt_tokens_details"] as? [String: Any] ?? [:]),
                reasoning: n("reasoning_tokens", in: u["completion_tokens_details"] as? [String: Any] ?? [:]))
        case .gemini:
            let thoughts = n("thoughtsTokenCount")
            let candidate = n("candidatesTokenCount")
            result = TokenUsage(input: n("promptTokenCount"),
                output: candidate.map { $0 + (thoughts ?? 0) }, total: n("totalTokenCount"),
                cachedInput: n("cachedContentTokenCount"), reasoning: thoughts)
        case .claude:
            let fresh = n("input_tokens")
            let cached = n("cache_read_input_tokens")
            let created = n("cache_creation_input_tokens")
            let input = (fresh != nil || cached != nil || created != nil)
                ? (fresh ?? 0) + (cached ?? 0) + (created ?? 0) : nil
            result = TokenUsage(input: input, output: n("output_tokens"), cachedInput: cached)
        }
        return result.isReported ? result : nil
    }
}

public struct UsageRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID // Assistant reply identity makes checkpoint/final writes idempotent.
    public var profileID: UUID
    public var model: String
    public var date: Date
    public var usage: TokenUsage?
    public var estimatedOutput: Int
    public var usageIsFinal: Bool?
    public var estimatedUnreportedOutput: Int {
        guard usageIsFinal != true else { return 0 }
        return max(0, estimatedOutput - (usage?.output ?? 0))
    }
    public init(id: UUID, profileID: UUID, model: String, date: Date = Date(),
                usage: TokenUsage?, estimatedOutput: Int, usageIsFinal: Bool = false) {
        self.id = id; self.profileID = profileID; self.model = model; self.date = date
        self.usage = usage; self.estimatedOutput = estimatedOutput
        self.usageIsFinal = usageIsFinal
    }
}

import CoreFoundation
