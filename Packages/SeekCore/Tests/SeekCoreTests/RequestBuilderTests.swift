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
