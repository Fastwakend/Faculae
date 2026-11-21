import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SeekCore

final class RequestBuilderTests: XCTestCase {
    private let key = "test-key-not-a-secret"
    private let messages = [ChatMessage(role: .user, content: "你好"), ChatMessage(role: .assistant, content: "你好！")]

    private func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testOpenAICompatiblePayloadAndPrefix() throws {
        let profile = APIProfile(name: "Relay", provider: .openAI, baseURL: "https://relay.example/ai/v1/", model: "some-org/model", systemPrompt: "简洁回答")
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: messages)
        XCTAssertEqual(request.url?.absoluteString, "https://relay.example/ai/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
        let json = try body(request)
        let turns = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertEqual(turns.map { $0["role"]! }, ["system", "user", "assistant"])
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertNil(json["temperature"])
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertFalse(try XCTUnwrap(request.url).absoluteString.contains(key))
    }

    func testPastedFullEndpointIsNotDuplicated() throws {
        for (provider, suffix) in [(APIProvider.openAI, "chat/completions"), (.claude, "messages")] {
            let profile = APIProfile(name: "test", provider: provider, baseURL: "https://relay.example/v1/" + suffix)
            let request = try RequestBuilder.chat(profile: profile, key: key, messages: messages)
            XCTAssertEqual(request.url?.path, "/v1/" + suffix)
            let models = try RequestBuilder.models(profile: profile, key: key)
            XCTAssertEqual(models.url?.path, "/v1/models")
        }
    }

    func testDeepSeekDoesNotGainAnUnrequestedV1Prefix() throws {
        let request = try RequestBuilder.chat(profile: APIProfile.presets[0], key: key, messages: messages)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertNil(try body(request)["tools"])
    }

    func testDeepSeekHostedToolsUseChatCompletionsDeclaration() throws {
        let request = try RequestBuilder.chat(profile: APIProfile.presets[0], key: key, messages: messages,
                                             webTools: .deepSeekHosted)
        let json = try body(request)
        XCTAssertEqual(json["tools"] as? [[String: String]],
                       [["type": "deepseek_web_search"], ["type": "deepseek_read_url"]])
        XCTAssertNil(json["tool_choice"])
    }

    func testDeepSeekHostedReplaysSignedLinkOnlyToTheSameOfficialModel() throws {
        let profile = APIProfile(name: "DeepSeek", provider: .openAI, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        var earlierReply = ChatMessage(role: .assistant, content: "Page summary [1](https://example.com)",
                                       model: profile.model, modelProvider: .openAI)
        earlierReply.hostedSearchHistory = #"{"role":"assistant","content":"Page summary","reasoning_content":"","server_tool_calls":[{"index":0,"calls":[{"id":"srvtoolu_1","kind":"read_link","signature":"signed-page"}]}]}"#
        let history = [ChatMessage(role: .user, content: "Read https://example.com"), earlierReply,
                       ChatMessage(role: .user, content: "What else does the page say?")]

        let request = try RequestBuilder.chat(profile: profile, key: key, messages: history, webTools: .deepSeekHosted)
        let context = try XCTUnwrap(body(request)["messages"] as? [[String: Any]])
        XCTAssertEqual(context[1]["content"] as? String, "Page summary")
        let steps = try XCTUnwrap(context[1]["server_tool_calls"] as? [[String: Any]])
        let calls = try XCTUnwrap(steps.first?["calls"] as? [[String: String]])
        XCTAssertEqual(calls.first?["signature"], "signed-page")

        var relay = profile
        relay.baseURL = "https://relay.example/v1"
        var differentModel = profile
        differentModel.model = "deepseek-v4-pro"
        let otherRequests: [(APIProfile, ChatWebTools)] = [(profile, .none), (profile, .client),
                                                           (relay, .deepSeekHosted), (differentModel, .deepSeekHosted)]
        for (otherProfile, mode) in otherRequests {
            let request = try RequestBuilder.chat(profile: otherProfile, key: key, messages: history, webTools: mode)
            let context = try XCTUnwrap(body(request)["messages"] as? [[String: Any]])
            XCTAssertEqual(context[1]["content"] as? String, earlierReply.content)
            XCTAssertNil(context[1]["server_tool_calls"])
        }
    }

    func testOpenAIClientWebSearchReplaysAssistantAndToolCall() throws {
        let profile = APIProfile(name: "Relay", provider: .openAI, model: "deepseek-v4-pro")
        let call = ChatToolCall(id: "call_1", name: "web_search", argumentsJSON: #"{"queries":["release notes"]}"#)
        let assistant = #"{"role":"assistant","content":null,"reasoning_content":"Find the release notes.","tool_calls":[{"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\"queries\":[\"release notes\"]}"}}]}"#
        let result = ChatToolResult(call: call, content: #"{"results":[{"id":1}]}"#, isError: false)
        let turn = ChatToolTurn(assistantJSON: assistant, results: [result])
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: Array(messages.prefix(1)),
                                             webTools: .client, toolTurns: [turn])
        let json = try body(request)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let declaration = try XCTUnwrap(tools.first?["function"] as? [String: Any])
        let schema = try XCTUnwrap(declaration["parameters"] as? [String: Any])
        XCTAssertEqual(declaration["name"] as? String, "web_search")
        XCTAssertEqual(schema["required"] as? [String], ["queries"])
        XCTAssertEqual(json["tool_choice"] as? String, "auto")

        let context = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(context.compactMap { $0["role"] as? String }, ["user", "assistant", "tool"])
        XCTAssertEqual(context[1]["reasoning_content"] as? String, "Find the release notes.")
        let calls = try XCTUnwrap(context[1]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls.first?["id"] as? String, call.id)
        XCTAssertEqual(context[2]["tool_call_id"] as? String, call.id)
        XCTAssertEqual(context[2]["content"] as? String, result.content)
    }

    func testDeepSeekThinkingWithFunctionToolsReplaysCompatibleHistoricalReasoning() throws {
        var profile = APIProfile(name: "DeepSeek", provider: .openAI, baseURL: "https://api.deepseek.com", model: "deepseek-flash")
        let history = [ChatMessage(role: .user, content: "Earlier question"),
                       ChatMessage(role: .assistant, content: "Earlier answer", reasoning: "Earlier thinking", model: profile.model, modelProvider: .openAI),
                       ChatMessage(role: .user, content: "Follow-up"),
                       ChatMessage(role: .assistant, content: "Other answer", reasoning: "Other thinking", model: "another-model", modelProvider: .openAI),
                       ChatMessage(role: .user, content: "New question")]
        let clientBody = try body(RequestBuilder.chat(profile: profile, key: key, messages: history, webTools: .client))
        let clientMessages = try XCTUnwrap(clientBody["messages"] as? [[String: String]])
        XCTAssertEqual(clientMessages[1]["reasoning_content"], "Earlier thinking")
        XCTAssertNil(clientMessages[3]["reasoning_content"])

        for mode in [ChatWebTools.none, .deepSeekHosted] {
            let json = try body(RequestBuilder.chat(profile: profile, key: key, messages: history, webTools: mode))
            let context = try XCTUnwrap(json["messages"] as? [[String: String]])
            XCTAssertNil(context[1]["reasoning_content"])
        }

        profile.reasoningLevel = ReasoningLevel.off
        let json = try body(RequestBuilder.chat(profile: profile, key: key, messages: history, webTools: .client))
        let context = try XCTUnwrap(json["messages"] as? [[String: String]])
        XCTAssertNil(context[1]["reasoning_content"])
    }

    func testGeminiClientWebSearchPreservesThoughtSignatureAndOptionalCallID() throws {
        let profile = APIProfile(name: "Gemini", provider: .gemini)
        let identified = ChatToolCall(id: "fc-1", name: "web_search", argumentsJSON: #"{"queries":["release"]}"#)
        let legacy = ChatToolCall(id: "generated-local", name: "web_search", argumentsJSON: #"{"queries":["changelog"]}"#)
        let assistant = #"{"role":"model","parts":[{"thoughtSignature":"opaque==","functionCall":{"id":"fc-1","name":"web_search","args":{"queries":["release"]}}},{"functionCall":{"name":"web_search","args":{"queries":["changelog"]}}}]}"#
        let results = [identified, legacy].map { ChatToolResult(call: $0, content: #"{"results":[]}"#, isError: false) }
        let turn = ChatToolTurn(assistantJSON: assistant, results: results)
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: Array(messages.prefix(1)),
                                             webTools: .clientFinal, toolTurns: [turn])
        let json = try body(request)
        let config = try XCTUnwrap(json["toolConfig"] as? [String: [String: String]])
        XCTAssertEqual(config["functionCallingConfig"]?["mode"], "NONE")
        let tools = try XCTUnwrap(json["tools"] as? [[String: [[String: Any]]]])
        XCTAssertEqual(tools.first?["functionDeclarations"]?.first?["name"] as? String, "web_search")

        let context = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(context.compactMap { $0["role"] as? String }, ["user", "model", "user"])
        let modelParts = try XCTUnwrap(context[1]["parts"] as? [[String: Any]])
        XCTAssertEqual(modelParts.first?["thoughtSignature"] as? String, "opaque==")
        let userParts = try XCTUnwrap(context[2]["parts"] as? [[String: [String: Any]]])
        XCTAssertEqual(userParts[0]["functionResponse"]?["id"] as? String, identified.id)
        XCTAssertNil(userParts[1]["functionResponse"]?["id"])
        XCTAssertEqual(userParts[1]["functionResponse"]?["name"] as? String, legacy.name)
        let response = try XCTUnwrap(userParts[1]["functionResponse"]?["response"] as? [String: [Any]])
        XCTAssertEqual(response["results"]?.count, 0)
    }

    func testClaudeClientWebSearchReplaysSignedThinkingAndReportsToolFailure() throws {
        let profile = APIProfile(name: "Claude", provider: .claude)
        let call = ChatToolCall(id: "toolu_1", name: "web_search", argumentsJSON: #"{"queries":["release notes"]}"#)
        let assistant = #"{"role":"assistant","content":[{"type":"thinking","thinking":"Look for a primary source.","signature":"opaque=="},{"type":"tool_use","id":"toolu_1","name":"web_search","input":{"queries":["release notes"]}}]}"#
        let failure = ChatToolResult(call: call, content: #"{"status":"search_failed"}"#, isError: true)
        let turn = ChatToolTurn(assistantJSON: assistant, results: [failure])
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: Array(messages.prefix(1)),
                                             webTools: .clientFinal, toolTurns: [turn])
        let json = try body(request)
        XCTAssertEqual(json["tool_choice"] as? [String: String], ["type": "none"])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["name"] as? String, "web_search")
        XCTAssertNotNil(tools.first?["input_schema"])

        let context = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(context.compactMap { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistantBlocks = try XCTUnwrap(context[1]["content"] as? [[String: Any]])
        let resultBlocks = try XCTUnwrap(context[2]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.first?["signature"] as? String, "opaque==")
        XCTAssertEqual(resultBlocks.first?["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlocks.first?["tool_use_id"] as? String, call.id)
        XCTAssertEqual(resultBlocks.first?["content"] as? String, failure.content)
        XCTAssertEqual(resultBlocks.first?["is_error"] as? Bool, true)
    }

    func testGeminiUsesNativeContentsAndHeaderAuthentication() throws {
        let profile = APIProfile(name: "Gemini", provider: .gemini, model: "models/gemini-2.5-flash", systemPrompt: "You are helpful.")
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: messages)
        XCTAssertEqual(request.url?.path, "/v1beta/models/gemini-2.5-flash:streamGenerateContent")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.query, "alt=sse")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request)
        let contents = try XCTUnwrap(json["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.map { $0["role"] as! String }, ["user", "model"])
        XCTAssertNotNil(json["systemInstruction"])
        XCTAssertNil(json["messages"])
    }

    func testClaudeUsesNativeSystemAndVersion() throws {
        let profile = APIProfile(name: "Claude", provider: .claude, systemPrompt: "Answer clearly.", sendsTemperature: true)
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: messages)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let json = try body(request)
        XCTAssertEqual(json["system"] as? String, "Answer clearly.")
        XCTAssertEqual(json["temperature"] as? Double, 0.7)
        XCTAssertEqual(json["max_tokens"] as? Int, 4096)
        XCTAssertEqual((json["messages"] as? [[String: Any]])?.count, 2)
    }

    func testReasoningModelsUseCompletionTokenParameter() throws {
        let profile = APIProfile(name: "Reasoning", provider: .openAI, model: "o3-mini")
        let json = try body(RequestBuilder.chat(profile: profile, key: key, messages: messages))
        XCTAssertNotNil(json["max_completion_tokens"])
        XCTAssertNil(json["max_tokens"])
    }

    func testFailedAndEmptyAssistantTurnsAreNotResent() throws {
        let context = [ChatMessage(role: .user, content: "question"),
                       ChatMessage(role: .assistant, content: "partial error", status: .failed),
                       ChatMessage(role: .assistant, status: .streaming),
                       ChatMessage(role: .assistant, content: "partial kept", reasoning: "private thoughts", status: .stopped)]
        let request = try RequestBuilder.chat(profile: APIProfile.presets[0], key: key, messages: context)
        let turns = try XCTUnwrap(body(request)["messages"] as? [[String: String]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.last?["content"], "partial kept")
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains("private thoughts"))
    }

    func testRejectsUnsafeOrAmbiguousURLs() {
        for url in ["http://relay.example/v1", "https://user:password@relay.example", "https://relay.example?key=x", "https://relay.example/#fragment", "file:///tmp/data", ""] {
            let profile = APIProfile(name: "Bad", provider: .openAI, baseURL: url)
            XCTAssertThrowsError(try RequestBuilder.chat(profile: profile, key: key, messages: messages), url)
        }
    }

    func testFailedTurnFollowedByNewQuestionKeepsGeminiRolesAlternating() throws {
        let context = [ChatMessage(role: .user, content: "first"),
                       ChatMessage(role: .assistant, content: "partial", status: .failed),
                       ChatMessage(role: .user, content: "second")]
        let profile = APIProfile(name: "g", provider: .gemini)
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: context)
        let contents = try XCTUnwrap(body(request)["contents"] as? [[String: Any]])
        XCTAssertEqual(contents.count, 1)
        let parts = try XCTUnwrap(contents[0]["parts"] as? [[String: String]])
        XCTAssertEqual(parts[0]["text"], "first\n\nsecond")
    }

    func testRejectsInvalidKeysModelsAndParameters() {
        let profile = APIProfile(name: "test", provider: .claude)
        XCTAssertThrowsError(try RequestBuilder.chat(profile: profile, key: "", messages: messages))
        XCTAssertThrowsError(try RequestBuilder.chat(profile: profile, key: "key\r\nInjected: x", messages: messages))
        var bad = profile
        bad.maxOutputTokens = 0
        XCTAssertThrowsError(try RequestBuilder.validate(bad))
        bad = profile; bad.model = "   "
        XCTAssertThrowsError(try RequestBuilder.validate(bad))
        bad = profile; bad.temperature = .nan
        XCTAssertThrowsError(try RequestBuilder.validate(bad))
        bad = APIProfile(name: "Gemini", provider: .gemini, model: "models/../../other?key=x")
        XCTAssertThrowsError(try RequestBuilder.validate(bad))
    }

    func testAPIKeysRejectEmbeddedLineBreaksForEveryProvider() {
        for provider in [APIProvider.openAI, .gemini, .claude] {
            let profile = APIProfile(name: "test", provider: provider)
            for separator in ["\r", "\n", "\r\n"] {
                let invalidKey = "key" + separator + "Injected: x"
                XCTAssertThrowsError(try RequestBuilder.chat(profile: profile, key: invalidKey, messages: messages),
                                     "Chat key must reject embedded CR/LF for \(provider)")
                XCTAssertThrowsError(try RequestBuilder.models(profile: profile, key: invalidKey),
                                     "Model-list key must reject embedded CR/LF for \(provider)")
            }
        }
    }

    func testAPIKeysAllowPastedBoundaryWhitespace() throws {
        for provider in [APIProvider.openAI, .gemini, .claude] {
            let profile = APIProfile(name: "test", provider: provider)
            let request = try RequestBuilder.models(profile: profile, key: " \r\n\t" + key + "\r\n ")
            switch provider {
            case .openAI: XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + key)
            case .gemini: XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), key)
            case .claude: XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
            }
        }
    }

    func testModelListPaginationRequests() throws {
        let gemini = try RequestBuilder.models(profile: APIProfile(name: "g", provider: .gemini), key: key, pageToken: "a+b/c=")
        let query = URLComponents(url: gemini.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "a+b/c=")
        let claude = try RequestBuilder.models(profile: APIProfile(name: "c", provider: .claude), key: key, pageToken: "model-last")
        XCTAssertEqual(URLComponents(url: claude.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "after_id")
    }
}
