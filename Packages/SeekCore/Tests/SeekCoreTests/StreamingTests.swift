import XCTest
import Foundation
@testable import SeekCore

final class StreamingTests: XCTestCase {
    func testByteByByteUTF8AndMixedNewlines() throws {
        let stream = "\u{FEFF}: heartbeat\r\nevent: content_block_delta\r\ndata: {\"text\":\"你好 🌊\"}\r\n\r\ndata: [DONE]\n\n"
        var parser = SSEParser()
        var events: [SSEEvent] = []
        for byte in stream.utf8 { events += try parser.append(Data([byte])) }
        XCTAssertEqual(events, [SSEEvent(name: "content_block_delta", data: "{\"text\":\"你好 🌊\"}"), SSEEvent(data: "[DONE]")])
        XCTAssertTrue(parser.finish().isEmpty)
    }

    func testMultilineDataCommentsAndEOF() throws {
        var parser = SSEParser()
        let data = Data(": ping\n\nevent: custom\ndata: first\ndata: second\n\ndata: tail".utf8)
        XCTAssertEqual(try parser.append(data), [SSEEvent(name: "custom", data: "first\nsecond")])
        XCTAssertEqual(parser.finish(), [SSEEvent(data: "tail")])
    }

    func testCarriageReturnOnlyAndEmptyData() throws {
        var parser = SSEParser()
        XCTAssertEqual(try parser.append(Data("data:\r\rdata: next\r\r".utf8)), [SSEEvent(data: ""), SSEEvent(data: "next")])
    }

    func testEventLimitPreventsUnboundedBuffering() {
        var parser = SSEParser(maximumEventBytes: 16)
        XCTAssertThrowsError(try parser.append(Data("data: 01234567890123456789".utf8)))
    }

    func testOpenAITextAndDeepSeekReasoning() throws {
        let first = try decode(#"{"choices":[{"delta":{"reasoning_content":"先想一想"},"finish_reason":null}]}"#, .openAI)
        XCTAssertEqual(first.reasoning, "先想一想")
        let second = try decode(#"{"choices":[{"delta":{"content":"答案"},"finish_reason":"stop"}]}"#, .openAI)
        XCTAssertEqual(second.text, "答案")
        XCTAssertTrue(second.isFinished)
        XCTAssertTrue(try decode("[DONE]", .openAI).isFinished)
    }

    func testGeminiThoughtPartsAndAnswer() throws {
        let delta = try decode(#"{"candidates":[{"content":{"parts":[{"text":"计划","thought":true},{"text":"结果"}]},"finishReason":"STOP"}]}"#, .gemini)
        XCTAssertEqual(delta, ReplyDelta(text: "结果", reasoning: "计划", isFinished: true))
    }

    func testGeminiSafetyBlockIsAnError() {
        XCTAssertThrowsError(try decode(#"{"promptFeedback":{"blockReason":"SAFETY"}}"#, .gemini))
        XCTAssertThrowsError(try decode(#"{"candidates":[{"finishReason":"RECITATION"}]}"#, .gemini))
    }

    func testClaudeNativeEvents() throws {
        XCTAssertEqual(try decode(#"{"type":"content_block_start","content_block":{"type":"text","text":"初始"}}"#, .claude).text, "初始")
        XCTAssertEqual(try decode(#"{"type":"content_block_delta","delta":{"type":"text_delta","text":"后续"}}"#, .claude).text, "后续")
        XCTAssertEqual(try decode(#"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"思路"}}"#, .claude).reasoning, "思路")
        XCTAssertTrue(try decode(#"{"type":"message_stop"}"#, .claude).isFinished)
        XCTAssertEqual(try decode(#"{"type":"ping"}"#, .claude), ReplyDelta())
    }

    func testProviderErrorsAreNeverTreatedAsEmptySuccessfulResponses() {
        for provider in APIProvider.allCases {
            XCTAssertThrowsError(try decode(#"{"error":{"message":"quota exhausted"}}"#, provider)) { error in
                XCTAssertEqual(error as? APIError, .provider("quota exhausted"))
            }
        }
        XCTAssertThrowsError(try decode("<html>not an API</html>", .openAI))
    }

    func testNonStreamingJSONFallbacks() throws {
        XCTAssertEqual(try decode(#"{"choices":[{"message":{"content":"whole reply"},"finish_reason":"stop"}]}"#, .openAI).text, "whole reply")
        XCTAssertEqual(try decode(#"{"type":"message","content":[{"type":"text","text":"whole reply"}]}"#, .claude).text, "whole reply")
    }

    func testModelDiscoveryFiltersGeminiEmbeddingModelsAndKeepsPagination() throws {
        let data = Data(#"{"models":[{"name":"models/chat","supportedGenerationMethods":["generateContent"]},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"next"}"#.utf8)
        let result = try ResponseDecoder.models(data, provider: .gemini)
        XCTAssertEqual(result.ids, ["chat"])
        XCTAssertEqual(result.nextPage, "next")
        let claude = Data(#"{"data":[{"id":"claude-test"}],"has_more":true,"last_id":"last"}"#.utf8)
        XCTAssertEqual(try ResponseDecoder.models(claude, provider: .claude).nextPage, "last")
    }

    func testHTTPErrorHidesHTMLResponseBody() {
        let error = ResponseDecoder.httpError(Data("<html>internal credentials</html>".utf8), status: 502)
        XCTAssertFalse(error.localizedDescription.contains("internal credentials"))
        XCTAssertTrue(error.localizedDescription.contains("502"))
    }

    func testSavedConversationContainsNoAPIKeyFieldAndRoundTrips() throws {
        let chat = Conversation(profileID: UUID(), messages: [ChatMessage(role: .user, content: "保留中文 🌊")])
        let data = try JSONEncoder().encode(chat)
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: data), chat)
        let profile = try JSONEncoder().encode(APIProfile.presets[0])
        XCTAssertFalse(String(data: profile, encoding: .utf8)!.lowercased().contains("apikey"))
        XCTAssertTrue(chat.markdown.contains("保留中文 🌊"))
    }

    private func decode(_ json: String, _ provider: APIProvider) throws -> ReplyDelta {
        try ResponseDecoder.delta(SSEEvent(data: json), provider: provider)
    }
}
