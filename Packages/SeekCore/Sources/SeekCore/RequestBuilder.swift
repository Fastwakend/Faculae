import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RequestBuilder {
    public static func validateAllModels(_ profile: APIProfile) throws {
        var seen = Set<String>()
        for entry in profile.models {
            var candidate = profile
            candidate.selectModel(entry.id)
            try validate(candidate)
            var model = candidate.model.trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.provider == .gemini && model.hasPrefix("models/") { model = String(model.dropFirst(7)) }
            guard seen.insert(model).inserted else { throw ModelSettingsError.duplicateModel }
        }
    }

    public static func validate(_ profile: APIProfile) throws {
        _ = try baseURL(profile)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw APIError.invalidModel }
        if profile.provider == .gemini {
            let short = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            guard !short.isEmpty, !short.contains(where: { "/?#\\ \n\r".contains($0) }) else {
                throw APIError.invalidModel
            }
        }
        guard (1...131072).contains(profile.maxOutputTokens), profile.temperature.isFinite,
              (0...1).contains(profile.temperature) else { throw APIError.invalidParameters }
    }

    public static func chat(profile: APIProfile, key: String, messages: [ChatMessage],
                            attachmentData: [UUID: Data] = [:], attachmentFiles: [UUID: URL]? = nil,
                            bodyFile: URL? = nil, webTools: ChatWebTools = .none,
                            toolTurns: [ChatToolTurn] = []) throws -> URLRequest {
        try validate(profile)
        var url = try baseURL(profile)
        let model = profile.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = normalizedContext(messages)
        let continuation = try toolTurns.flatMap { try toolMessages($0, provider: profile.provider) }
        if let files = attachmentFiles {
            guard bodyFile != nil else { throw APIError.invalidParameters }
            var total = 0
            for attachment in context.flatMap({ $0.attachments ?? [] }) {
                guard let file = files[attachment.id] else { throw APIError.provider("附件读取失败，请重新添加。") }
                total += try AttachmentFileIO.size(file)
                guard total <= AttachmentLimits.batchBytes else { throw APIError.provider("请求附件总大小不能超过 6 GB。") }
            }
        } else { try validateAttachments(context, data: attachmentData) }
        var body: [String: Any]
        switch profile.provider {
        case .openAI:
            url = url.appendingPathComponent("chat/completions")
            let replayHostedHistory = webTools == .deepSeekHosted && WebSearch.supportsDeepSeekHosted(profile)
            let replayDeepSeekReasoning = (webTools == .client || webTools == .clientFinal)
                && profile.reasoningControl == .deepSeek && profile.explicitReasoningLevel != .off
            var items: [[String: Any]] = try context.map { message in
                if replayHostedHistory, message.role == .assistant, message.model == model, message.modelProvider == .openAI,
                   let raw = message.hostedSearchHistory, let history = try? toolJSONObject(raw),
                   history["role"] as? String == "assistant",
                   let calls = history["server_tool_calls"] as? [[String: Any]], !calls.isEmpty {
                    return history
                }
                var item: [String: Any] = ["role": message.role.rawValue,
                    "content": try content(message, provider: .openAI, data: attachmentData, files: attachmentFiles)]
                // DeepSeek thinking with function tools requires reasoning from earlier assistant messages.
                if replayDeepSeekReasoning, message.role == .assistant, message.model == model,
                   message.modelProvider == nil || message.modelProvider == .openAI {
                    item["reasoning_content"] = message.reasoning
                }
                return item
            }
            if !profile.systemPrompt.isEmpty {
                items.insert(["role": "system", "content": profile.systemPrompt], at: 0)
            }
            body = ["model": model, "messages": items + continuation, "stream": true, "stream_options": ["include_usage": true]]
            // Reasoning models on OpenAI use max_completion_tokens; compatible services commonly use max_tokens.
            let isOpenAIReasoning = ["o1", "o3", "o4", "gpt-5", "gpt-6"].contains { model.hasPrefix($0) }
            body[isOpenAIReasoning ? "max_completion_tokens" : "max_tokens"] = profile.maxOutputTokens
            if profile.sendsTemperature { body["temperature"] = profile.temperature }
            if let level = profile.explicitReasoningLevel {
                if profile.reasoningControl == .deepSeek {
                    body["thinking"] = ["type": level == .off ? "disabled" : "enabled"]
                    body["reasoning_effort"] = level == .off ? "none" : level.rawValue
                    if level != .off { body.removeValue(forKey: "temperature") }
                } else {
                    body["reasoning_effort"] = level.rawValue
                }
            }
        case .gemini:
            let short = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
            url = url.appendingPathComponent("models").appendingPathComponent(short + ":streamGenerateContent")
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "alt", value: "sse")]
            url = components.url!
            var generation: [String: Any] = ["maxOutputTokens": profile.maxOutputTokens]
            if profile.sendsTemperature { generation["temperature"] = profile.temperature }
            if let level = profile.explicitReasoningLevel {
                if profile.reasoningControl == .geminiBudget {
                    guard profile.maxOutputTokens > 1024 else { throw APIError.provider("请先将最大输出设置为大于 1024 tokens，再调整推理等级。") }
                    generation["thinkingConfig"] = ["thinkingBudget": profile.reasoningBudget]
                } else if profile.reasoningControl == .geminiLevel {
                    generation["thinkingConfig"] = ["thinkingLevel": level.rawValue.uppercased()]
                }
            }
            let items = try context.map { ["role": $0.role == .user ? "user" : "model", "parts": try content($0, provider: .gemini, data: attachmentData, files: attachmentFiles)] }
            body = ["contents": items + continuation,
                    "generationConfig": generation]
            if !profile.systemPrompt.isEmpty {
                body["systemInstruction"] = ["parts": [["text": profile.systemPrompt]]]
            }
        case .claude:
            url = url.appendingPathComponent("messages")
            let items = try context.map { ["role": $0.role.rawValue, "content": try content($0, provider: .claude, data: attachmentData, files: attachmentFiles)] }
            body = ["model": model, "max_tokens": profile.maxOutputTokens, "stream": true,
                    "messages": items + continuation]
            if !profile.systemPrompt.isEmpty { body["system"] = profile.systemPrompt }
            if profile.sendsTemperature { body["temperature"] = profile.temperature }
            if let level = profile.explicitReasoningLevel {
                if profile.reasoningControl == .deepSeek {
                    body["reasoning"] = ["effort": level == .off ? "none" : level.rawValue]
                    if level != .off { body["output_config"] = ["effort": level.rawValue]; body.removeValue(forKey: "temperature") }
                } else if profile.reasoningControl == .claudeAdaptive {
                    body["thinking"] = ["type": "adaptive"]
                    body["output_config"] = ["effort": level.rawValue]
                    body.removeValue(forKey: "temperature")
                } else if profile.reasoningControl == .claudeBudget {
                    guard profile.maxOutputTokens > 1024 else { throw APIError.provider("Claude 推理预算至少为 1024 tokens，请提高最大输出。") }
                    body["thinking"] = ["type": "enabled", "budget_tokens": profile.reasoningBudget]
                    body.removeValue(forKey: "temperature")
                }
            }
        }
        try configureWebTools(webTools, provider: profile.provider, body: &body)
        var request = try authorizedRequest(url: url, profile: profile, key: key)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream, application/json", forHTTPHeaderField: "Accept")
        if let bodyFile {
            try FileJSONWriter.write(body, to: bodyFile)
            request.setValue(String(try bodyFile.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0), forHTTPHeaderField: "Content-Length")
        } else { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        return request
    }

    private static func configureWebTools(_ mode: ChatWebTools, provider: APIProvider, body: inout [String: Any]) throws {
        let canCall: Bool
        switch mode {
        case .none:
            return
        case .deepSeekHosted:
            guard provider == .openAI else { throw APIError.invalidParameters }
            body["tools"] = [["type": "deepseek_web_search"], ["type": "deepseek_read_url"]]
            return
        case .client: canCall = true
        case .clientFinal: canCall = false
        }

        let name = "web_search"
        let description = "Search for current information or verify facts against public sources."
        let maxQueries = ChatSearchSession.queriesPerRound
        let queriesDescription = "Between 1 and \(maxQueries) concise, distinct public search queries."
        var schema: [String: Any] = [
            "type": "object",
            "properties": ["queries": ["type": "array", "items": ["type": "string"],
                                         "description": queriesDescription, "minItems": 1, "maxItems": maxQueries]],
            "required": ["queries"]
        ]
        switch provider {
        case .openAI:
            body["tools"] = [["type": "function", "function": ["name": name, "description": description, "parameters": schema]]]
            body["tool_choice"] = canCall ? "auto" : "none"
        case .gemini:
            schema["type"] = "OBJECT"
            schema["properties"] = ["queries": ["type": "ARRAY", "items": ["type": "STRING"],
                                                 "description": queriesDescription, "minItems": "1", "maxItems": String(maxQueries)]]
            body["tools"] = [["functionDeclarations": [["name": name, "description": description, "parameters": schema]]]]
            body["toolConfig"] = ["functionCallingConfig": ["mode": canCall ? "AUTO" : "NONE"]]
        case .claude:
            body["tools"] = [["name": name, "description": description, "input_schema": schema]]
            body["tool_choice"] = ["type": canCall ? "auto" : "none"]
        }
    }

    private static func toolMessages(_ turn: ChatToolTurn, provider: APIProvider) throws -> [[String: Any]] {
        let assistant = try toolJSONObject(turn.assistantJSON)
        guard assistant["role"] as? String == (provider == .gemini ? "model" : "assistant") else {
            throw APIError.malformedResponse
        }
        switch provider {
        case .openAI:
            return [assistant] + turn.results.map { result in
                ["role": "tool", "tool_call_id": result.call.id, "content": result.content]
            }
        case .gemini:
            let parts = assistant["parts"] as? [[String: Any]] ?? []
            let callIDs = Set(parts.compactMap { ($0["functionCall"] as? [String: Any])?["id"] as? String })
            let responses = try turn.results.map { result -> [String: Any] in
                var response: [String: Any] = ["name": result.call.name, "response": try toolJSONObject(result.content)]
                if callIDs.contains(result.call.id) { response["id"] = result.call.id }
                return ["functionResponse": response]
            }
            return [assistant, ["role": "user", "parts": responses]]
        case .claude:
            let blocks: [[String: Any]] = turn.results.map { result in
                ["type": "tool_result", "tool_use_id": result.call.id, "content": result.content, "is_error": result.isError]
            }
            return [assistant, ["role": "user", "content": blocks]]
        }
    }

    private static func toolJSONObject(_ json: String) throws -> [String: Any] {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw APIError.malformedResponse
        }
        return object
    }

    public static func models(profile: APIProfile, key: String, pageToken: String? = nil) throws -> URLRequest {
        var url = try baseURL(profile).appendingPathComponent("models")
        if profile.provider == .gemini {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
            if let pageToken { components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            url = components.url!
        } else if profile.provider == .claude, let pageToken {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "after_id", value: pageToken)]
            url = components.url!
        }
        var request = try authorizedRequest(url: url, profile: profile, key: key)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    public static func balance(profile: APIProfile, key: String, configuration: BalanceConfiguration) throws -> URLRequest {
        let base = try baseURL(profile)
        let url = try BalanceJSON.endpoint(configuration.endpoint, relativeTo: base)
        var request = try authorizedRequest(url: url, profile: profile, key: key)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func normalizedContext(_ messages: [ChatMessage]) -> [ChatMessage] {
        var result: [ChatMessage] = []
        for original in messages where original.isValidContext {
            var message = original
            // A generated assistant image is an output asset, not an implicit
            // new image input when the user switches back to a chat model.
            if message.imageGenerationSettings != nil { message.attachments = nil }
            // Failed assistant turns can leave consecutive user turns. Gemini requires alternating roles.
            if result.last?.role == message.role {
                result[result.count - 1].content += "\n\n" + message.content
                let combined = (result[result.count - 1].attachments ?? []) + (message.attachments ?? [])
                result[result.count - 1].attachments = combined.isEmpty ? nil : combined
                result[result.count - 1].hostedSearchHistory = nil
            } else { result.append(message) }
        }
        return result
    }

    private static func validateAttachments(_ messages: [ChatMessage], data: [UUID: Data]) throws {
        let attachments = messages.flatMap { $0.attachments ?? [] }
        var total = 0
        for attachment in attachments {
            guard let bytes = data[attachment.id], !bytes.isEmpty else {
                throw APIError.provider("附件“\(attachment.name)”读取失败，请重新添加或新建对话。")
            }
            total += bytes.count
            guard bytes.count <= AttachmentLimits.fileBytes, total <= AttachmentLimits.batchBytes else {
                throw APIError.provider("每个附件最多 1 GB，每次请求的附件总计最多 6 GB。请减少附件或新建对话。")
            }
        }
    }

    private static func content(_ message: ChatMessage, provider: APIProvider, data: [UUID: Data], files: [UUID: URL]?) throws -> Any {
        let attachments = message.attachments ?? []
        if attachments.isEmpty {
            return provider == .gemini ? [["text": message.content]] as Any : message.content as Any
        }
        var parts: [[String: Any]] = []
        func addText(_ text: String) {
            if !text.isEmpty { parts.append(provider == .gemini ? ["text": text] : ["type": "text", "text": text]) }
        }
        addText(message.content)
        for attachment in attachments {
            if attachment.kind == .text {
                if let url = files?[attachment.id] {
                    let text = JSONFileString(url: url, encoding: .text, prefix: "附件：\(attachment.name)\n\n")
                    parts.append(provider == .gemini ? ["text": text] : ["type": "text", "text": text])
                } else {
                    guard let bytes = data[attachment.id], let text = String(data: bytes, encoding: .utf8) else { throw APIError.provider("文字附件须使用 UTF-8 编码。") }
                    addText("附件：\(attachment.name)\n\n" + text)
                }
                continue
            }
            func base64(prefix: String = "") throws -> Any {
                if let url = files?[attachment.id] { return JSONFileString(url: url, encoding: .base64, prefix: prefix) }
                guard let bytes = data[attachment.id] else { throw APIError.provider("附件读取失败。") }
                return prefix + bytes.base64EncodedString()
            }
            switch provider {
            case .openAI:
                if attachment.kind == .image {
                    parts.append(["type": "image_url", "image_url": ["url": try base64(prefix: "data:\(attachment.mimeType);base64,")]])
                } else {
                    parts.append(["type": "file", "file": ["filename": attachment.name, "file_data": try base64(prefix: "data:application/pdf;base64,")]])
                }
            case .gemini:
                parts.append(["inlineData": ["mimeType": attachment.mimeType, "data": try base64()]])
            case .claude:
                parts.append(["type": attachment.kind == .image ? "image" : "document",
                              "source": ["type": "base64", "media_type": attachment.mimeType, "data": try base64()]])
            }
        }
        return parts
    }

    static func baseURL(_ profile: APIProfile) throws -> URL {
        let raw = profile.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { throw APIError.invalidURL }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        // A pasted full endpoint is accepted as well as an API root.
        for suffix in ["/chat/completions", "/messages", "/images/generations", "/images/edits"] where path.hasSuffix(suffix) {
            path = String(path.dropLast(suffix.count))
        }
        if profile.provider == .gemini, let range = path.range(of: "/models/") {
            path = String(path[..<range.lowerBound])
        }
        parts.path = path
        guard let url = parts.url else { throw APIError.invalidURL }
        return url
    }

    static func authorizedRequest(url: URL, profile: APIProfile, key: String) throws -> URLRequest {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // CRLF is one extended grapheme cluster; inspect scalars consistently on Darwin and Linux.
        guard !cleanKey.isEmpty,
              !cleanKey.unicodeScalars.contains(where: { $0.value == 0x0A || $0.value == 0x0D }) else {
            throw APIError.missingKey
        }
        var request = URLRequest(url: url, timeoutInterval: 120)
        switch profile.provider {
        case .openAI: request.setValue("Bearer " + cleanKey, forHTTPHeaderField: "Authorization")
        case .gemini: request.setValue(cleanKey, forHTTPHeaderField: "x-goog-api-key")
        case .claude:
            request.setValue(cleanKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }
}
