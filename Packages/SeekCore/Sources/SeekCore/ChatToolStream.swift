import Foundation

/// Collects complete tool requests while passing displayable stream events to the reply.
public struct ChatToolStream {
    private struct OpenAICall {
        var id = ""
        var type = "function"
        var name = ""
        var arguments = ""

        mutating func append(_ fragment: [String: Any]) {
            if let id = fragment["id"] as? String { self.id = id }
            if let type = fragment["type"] as? String { self.type = type }
            let function = fragment["function"] as? [String: Any]
            name += function?["name"] as? String ?? ""
            arguments += function?["arguments"] as? String ?? ""
        }

        var json: [String: Any] {
            ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]]
        }
    }

    private struct ClaudeBlock {
        var json: [String: Any]
        var inputJSON = ""
        var closed = false

        mutating func append(_ delta: [String: Any]) {
            switch delta["type"] as? String {
            case "text_delta": append(delta, field: "text")
            case "thinking_delta": append(delta, field: "thinking")
            case "signature_delta": append(delta, field: "signature")
            case "input_json_delta": inputJSON += delta["partial_json"] as? String ?? ""
            default: break
            }
        }

        private mutating func append(_ delta: [String: Any], field: String) {
            if let fragment = delta[field] as? String {
                json[field] = (json[field] as? String ?? "") + fragment
            }
        }

        func completedJSON() throws -> [String: Any] {
            guard closed else { throw APIError.malformedResponse }
            guard json["type"] as? String == "tool_use", !inputJSON.isEmpty else { return json }
            guard let input = try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String: Any] else {
                throw APIError.malformedResponse
            }
            var block = json
            block["input"] = input
            return block
        }
    }

    private let provider: APIProvider
    private var finishReason: String?
    private var openAICalls: [Int: OpenAICall] = [:]
    private var openAIText = ""
    private var openAIReasoning: String?
    private var openAIWholeContent: Any?
    private var openAIHostedSteps: [[String: Any]]?
    private var geminiParts: [[String: Any]] = []
    private var claudeBlocks: [Int: ClaudeBlock] = [:]
    private var claudeFinished = false
    private var startedHostedCalls: Set<String> = []
    private var finishedHostedCalls: Set<String> = []

    public init(provider: APIProvider) {
        self.provider = provider
    }

    public mutating func consume(_ event: SSEEvent) throws -> ReplyDelta {
        guard let json = try ResponseDecoder.messageObject(event) else { return ReplyDelta(isFinished: true) }
        var delta = try ResponseDecoder.delta(json, eventName: event.name, provider: provider)
        switch provider {
        case .openAI:
            if let choice = (json["choices"] as? [[String: Any]])?.first {
                collectOpenAI(choice, text: delta.text)
            }
            var newEvents: [HostedSearchEvent] = []
            for event in delta.hostedSearchEvents {
                switch event {
                case .started(let id, _):
                    if startedHostedCalls.insert(id).inserted { newEvents.append(event) }
                case .finished(let id, _, _):
                    if finishedHostedCalls.insert(id).inserted { newEvents.append(event) }
                }
            }
            delta.hostedSearchEvents = newEvents
        case .gemini:
            if let candidate = (json["candidates"] as? [[String: Any]])?.first {
                let content = candidate["content"] as? [String: Any]
                geminiParts.append(contentsOf: content?["parts"] as? [[String: Any]] ?? [])
                if let reason = candidate["finishReason"] as? String { finishReason = reason }
            }
        case .claude:
            collectClaude(json, eventName: event.name)
        }
        return delta
    }

    public func result() throws -> ChatToolResponse {
        switch provider {
        case .openAI:
            if finishReason == "stop", let openAIHostedSteps {
                var message = openAIAssistant
                message["server_tool_calls"] = openAIHostedSteps
                return ChatToolResponse(hostedHistoryJSON: try jsonString(message))
            }
            guard finishReason == "tool_calls" else { return ChatToolResponse() }
            let tools = openAICalls.sorted { $0.key < $1.key }.map(\.value)
            guard tools.allSatisfy({ $0.type == "function" }) else { throw APIError.malformedResponse }
            let calls = tools.map { ChatToolCall(id: $0.id, name: $0.name, argumentsJSON: $0.arguments) }
            var message = openAIAssistant
            message["tool_calls"] = tools.map(\.json)
            return try response(assistant: message, calls: calls)
        case .gemini:
            guard finishReason == "STOP" else { return ChatToolResponse() }
            let tools = try geminiParts.compactMap { part -> [String: Any]? in
                guard let value = part["functionCall"] else { return nil }
                guard let tool = value as? [String: Any] else { throw APIError.malformedResponse }
                return tool
            }
            guard !tools.isEmpty else { return ChatToolResponse() }
            var ids = Set(tools.compactMap { $0["id"] as? String })
            let calls = try tools.enumerated().map { index, tool -> ChatToolCall in
                guard let name = tool["name"] as? String,
                      tool["willContinue"] as? Bool != true, tool["partialArgs"] == nil,
                      tool["args"] == nil || tool["args"] is [String: Any] else {
                    throw APIError.malformedResponse
                }
                var id = tool["id"] as? String ?? ""
                if id.isEmpty {
                    id = "gemini-call-\(index)"
                    while !ids.insert(id).inserted { id += "-" }
                }
                return ChatToolCall(id: id, name: name,
                                    argumentsJSON: try jsonString(tool["args"] as? [String: Any] ?? [:]))
            }
            return try response(assistant: ["role": "model", "parts": geminiParts], calls: calls)
        case .claude:
            guard claudeFinished, finishReason == "tool_use" else { return ChatToolResponse() }
            let content = try claudeBlocks.sorted { $0.key < $1.key }.map { try $0.value.completedJSON() }
            let calls = try content.filter { $0["type"] as? String == "tool_use" }.map { block -> ChatToolCall in
                guard let id = block["id"] as? String, let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any] else { throw APIError.malformedResponse }
                return ChatToolCall(id: id, name: name, argumentsJSON: try jsonString(input))
            }
            return try response(assistant: ["role": "assistant", "content": content], calls: calls)
        }
    }

    private var openAIAssistant: [String: Any] {
        let text: Any = openAIText.isEmpty && finishReason == "tool_calls" ? NSNull() : openAIText
        var message: [String: Any] = ["role": "assistant", "content": openAIWholeContent ?? text]
        if let openAIReasoning { message["reasoning_content"] = openAIReasoning }
        return message
    }

    private mutating func collectOpenAI(_ choice: [String: Any], text: String) {
        let wholeMessage = choice["message"] as? [String: Any]
        let content = choice["delta"] as? [String: Any] ?? wholeMessage ?? [:]
        openAIText += text
        if let wholeContent = wholeMessage?["content"] { openAIWholeContent = wholeContent }
        if (choice["server_tool_event"] as? [String: Any])?["type"] as? String == "step_reasoning_done" {
            // Earlier reasoning is already part of the server tool step, as in a complete response.
            openAIReasoning = nil
        }
        if let reasoning = content["reasoning_content"] as? String {
            openAIReasoning = (openAIReasoning ?? "") + reasoning
        }
        for (offset, call) in (content["tool_calls"] as? [[String: Any]] ?? []).enumerated() {
            let index = call["index"] as? Int ?? offset
            openAICalls[index, default: OpenAICall()].append(call)
        }
        if let reason = choice["finish_reason"] as? String {
            finishReason = reason
            if reason == "stop", let steps = content["server_tool_calls"] as? [[String: Any]],
               steps.contains(where: hasSignedRead) {
                openAIHostedSteps = steps
            }
        }
    }

    private func hasSignedRead(_ step: [String: Any]) -> Bool {
        (step["calls"] as? [[String: Any]] ?? []).contains { call in
            guard call["type"] as? String == "deepseek_read_url", call["kind"] as? String == "read_link",
                  call["status"] as? String == "completed", let signature = call["signature"] as? String else {
                return false
            }
            return !signature.isEmpty
        }
    }

    private mutating func collectClaude(_ json: [String: Any], eventName: String) {
        let index = json["index"] as? Int
        switch json["type"] as? String ?? eventName {
        case "content_block_start":
            if let index, let block = json["content_block"] as? [String: Any] {
                claudeBlocks[index] = ClaudeBlock(json: block)
            }
        case "content_block_delta":
            if let index, let delta = json["delta"] as? [String: Any] {
                claudeBlocks[index]?.append(delta)
            }
        case "content_block_stop":
            if let index { claudeBlocks[index]?.closed = true }
        case "message_delta":
            if let delta = json["delta"] as? [String: Any], let reason = delta["stop_reason"] as? String {
                finishReason = reason
            }
        case "message_stop":
            claudeFinished = true
        case "message":
            for (index, block) in (json["content"] as? [[String: Any]] ?? []).enumerated() {
                claudeBlocks[index] = ClaudeBlock(json: block, closed: true)
            }
            finishReason = json["stop_reason"] as? String
            claudeFinished = true
        default: break
        }
    }

    private func response(assistant: [String: Any], calls: [ChatToolCall]) throws -> ChatToolResponse {
        guard !calls.isEmpty, calls.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty }),
              Set(calls.map(\.id)).count == calls.count else { throw APIError.malformedResponse }
        return ChatToolResponse(assistantJSON: try jsonString(assistant), calls: calls)
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
