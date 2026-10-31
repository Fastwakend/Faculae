import Foundation

public enum ResponseDecoder {
    public static func delta(_ event: SSEEvent, provider: APIProvider) throws -> ReplyDelta {
        if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { return ReplyDelta(isFinished: true) }
        guard let data = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.malformedResponse
        }
        if let error = json["error"] { throw APIError.provider(errorMessage(error)) }
        let usage = TokenUsage.decode(json, provider: provider)
        switch provider {
        case .openAI:
            guard let choices = json["choices"] as? [[String: Any]] else {
                if json["usage"] != nil { return ReplyDelta(usage: usage) }
                throw APIError.malformedResponse
            }
            guard let choice = choices.first else { return ReplyDelta(usage: usage) }
            let delta = choice["delta"] as? [String: Any] ?? choice["message"] as? [String: Any] ?? [:]
            let finish = choice["finish_reason"] as? String
            if finish == "content_filter" { throw APIError.provider("内容被服务商的安全策略拦截。") }
            return ReplyDelta(text: textContent(delta["content"]),
                              reasoning: delta["reasoning_content"] as? String ?? delta["reasoning"] as? String ?? "",
                              isFinished: finish != nil, usage: usage)
        case .gemini:
            if let feedback = json["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw APIError.provider("Gemini 拦截了此请求：\(reason)")
            }
            guard let candidates = json["candidates"] as? [[String: Any]], let first = candidates.first else {
                if json["usageMetadata"] != nil { return ReplyDelta(usage: usage) }
                throw APIError.malformedResponse
            }
            let reason = first["finishReason"] as? String
            if let reason, !["STOP", "MAX_TOKENS"].contains(reason) {
                throw APIError.provider("Gemini 停止生成：\(reason)")
            }
            let content = first["content"] as? [String: Any]
            let parts = content?["parts"] as? [[String: Any]] ?? []
            var result = ReplyDelta(isFinished: reason != nil, usage: usage)
            for part in parts {
                guard let text = part["text"] as? String else { continue }
                if part["thought"] as? Bool == true { result.reasoning += text }
                else { result.text += text }
            }
            return result
        case .claude:
            switch json["type"] as? String ?? event.name {
            case "error": throw APIError.provider(errorMessage(json["error"] ?? json))
            case "message_stop": return ReplyDelta(isFinished: true, usage: usage)
            case "content_block_start":
                let block = json["content_block"] as? [String: Any] ?? [:]
                return ReplyDelta(text: block["text"] as? String ?? "", reasoning: block["thinking"] as? String ?? "")
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any] ?? [:]
                return ReplyDelta(text: delta["text"] as? String ?? "", reasoning: delta["thinking"] as? String ?? "")
            case "message":
                let blocks = json["content"] as? [[String: Any]] ?? []
                return ReplyDelta(text: blocks.compactMap { $0["text"] as? String }.joined(), isFinished: true, usage: usage)
            default: return ReplyDelta(usage: usage)
            }
        }
    }

    public static func models(_ data: Data, provider: APIProvider) throws -> (ids: [String], nextPage: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.malformedResponse }
        if let error = json["error"] { throw APIError.provider(errorMessage(error)) }
        if provider == .gemini {
            guard let models = json["models"] as? [[String: Any]] else { throw APIError.malformedResponse }
            let ids = models.filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
                .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            return (ids, json["nextPageToken"] as? String)
        }
        guard let items = json["data"] as? [[String: Any]] else { throw APIError.malformedResponse }
        let ids = items.compactMap { $0["id"] as? String }
        let next = provider == .claude && json["has_more"] as? Bool == true ? json["last_id"] as? String : nil
        return (ids, next)
    }

    public static func httpError(_ data: Data, status: Int) -> APIError {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return .http(status, errorMessage(json["error"] ?? json))
        }
        let fallback: String
        switch status {
        case 401, 403: fallback = "Key 无效或没有这个模型的访问权限。"
        case 404: fallback = "找不到接口或模型，请检查 API 地址和协议。"
        case 429: fallback = "请求过于频繁或额度不足，请稍后再试。"
        case 500...599: fallback = "服务暂时不可用，请稍后再试。"
        default: fallback = "请求失败，请检查服务配置。"
        }
        return .http(status, fallback)
    }

    private static func textContent(_ value: Any?) -> String {
        if let text = value as? String { return text }
        return (value as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined()
    }

    private static func errorMessage(_ value: Any) -> String {
        if let value = value as? String { return String(value.prefix(600)) }
        if let object = value as? [String: Any], let message = object["message"] as? String { return String(message.prefix(600)) }
        return "服务返回错误，请检查 Key、模型及配额。"
    }
}
