import XCTest
@testable import SeekCore

final class UsageBalanceTests: XCTestCase {
    func testBalanceDisplayUsesTwoDecimalsAndDecimalRounding() {
        for (raw, expected) in [("12", "12.00"), ("12.5", "12.50"), ("0", "0.00"),
                                ("1.005", "1.01"), ("-1.005", "-1.01"), ("-0.001", "0.00"),
                                ("9.999", "10.00"), (" 0.0001 ", "0.00"), ("1.234e2", "123.40"),
                                ("999999999999999.995", "1000000000000000.00")] {
            XCTAssertEqual(BalanceJSON.displayValue(raw), expected, raw)
        }
    }

    func testBalanceDisplayPreservesNonNumericValues() {
        for text in ["unlimited", "未开通", "12 USD", "NaN", "Infinity", "1.2.3", ""] {
            XCTAssertEqual(BalanceJSON.displayValue(text), text)
        }
    }

    func testOpenAIUsageOnlyTrailingEventAndCumulativeMerge() throws {
        let first = try ResponseDecoder.delta(SSEEvent(data: #"{"choices":[{"delta":{"content":"Hi"},"finish_reason":"stop"}]}"#), provider: .openAI)
        XCTAssertTrue(first.isFinished)
        let final = try ResponseDecoder.delta(SSEEvent(data: #"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":20,"total_tokens":120,"completion_tokens_details":{"reasoning_tokens":7},"prompt_tokens_details":{"cached_tokens":40}}}"#), provider: .openAI)
        var usage = TokenUsage()
        usage.merge(final.usage); usage.merge(final.usage)
        XCTAssertEqual(usage.totalTokens, 120)
        XCTAssertEqual(usage.reasoning, 7)
        XCTAssertEqual(usage.cachedInput, 40)
    }

    func testClaudeStartAndMessageDeltaUsageAreNotAddedTwice() throws {
        let start = try ResponseDecoder.delta(SSEEvent(data: #"{"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":20,"cache_creation_input_tokens":5,"output_tokens":1}}}"#), provider: .claude)
        let end = try ResponseDecoder.delta(SSEEvent(data: #"{"type":"message_delta","usage":{"output_tokens":42}}"#), provider: .claude)
        var usage = TokenUsage()
        usage.merge(start.usage); usage.merge(end.usage); usage.merge(end.usage)
        XCTAssertEqual(usage.input, 35)
        XCTAssertEqual(usage.output, 42)
        XCTAssertEqual(usage.totalTokens, 77)
    }

    func testGeminiIncludesThoughtsButDoesNotDoubleCountCachedTokens() throws {
        let delta = try ResponseDecoder.delta(SSEEvent(data: #"{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":20,"thoughtsTokenCount":30,"cachedContentTokenCount":60,"totalTokenCount":150}}"#), provider: .gemini)
        XCTAssertEqual(delta.usage?.output, 50)
        XCTAssertEqual(delta.usage?.totalTokens, 150)
    }

    func testMalformedUsageCannotBecomeHugeOrNegativeCounters() throws {
        let delta = try ResponseDecoder.delta(SSEEvent(data: #"{"usage":{"prompt_tokens":true,"completion_tokens":-10,"total_tokens":1e30}}"#), provider: .openAI)
        XCTAssertNil(delta.usage)
    }

    func testBalanceDotArraysAndJSONPointer() throws {
        let json = Data(#"{"data":{"items":[{"balance":"12.50"}]},"a/b":{"~balance":0}}"#.utf8)
        XCTAssertEqual(try BalanceJSON.value(json, path: "$.data.items[0].balance"), "12.50")
        XCTAssertEqual(try BalanceJSON.value(json, path: "/a~1b/~0balance"), "0")
        XCTAssertThrowsError(try BalanceJSON.value(json, path: "data.items[1].balance"))
        XCTAssertThrowsError(try BalanceJSON.value(json, path: "data.items"))
        XCTAssertThrowsError(try BalanceJSON.value(Data("{\"balance\":true}".utf8), path: "balance"))
    }

    func testBalanceKeyCannotBeForwardedToDifferentOriginOrCredentialsURL() throws {
        let base = URL(string: "https://api.example.com/v1")!
        XCTAssertEqual(try BalanceJSON.endpoint("/user/balance", relativeTo: base).absoluteString, "https://api.example.com/user/balance")
        XCTAssertEqual(try BalanceJSON.endpoint("balance", relativeTo: base).path, "/v1/balance")
        for path in ["https://other.example.com/balance", "//evil.example.com/b", "http://api.example.com/b", "https://api.example.com:444/b", "https://user@api.example.com/b"] {
            XCTAssertThrowsError(try BalanceJSON.endpoint(path, relativeTo: base))
        }
        let profile = APIProfile(name: "Claude", provider: .claude, baseURL: base.absoluteString)
        let request = try RequestBuilder.balance(profile: profile, key: "test-key", configuration: BalanceConfiguration(endpoint: "/balance"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "test-key")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testOldMessageDecodesWithoutUsageAndNewRecordRoundTrips() throws {
        let old = ChatMessage(role: .assistant, content: "old reply")
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertNil(decoded.tokenUsage)
        let record = UsageRecord(id: old.id, profileID: UUID(), model: "sample", usage: TokenUsage(input: 5, output: 8), estimatedOutput: 0)
        XCTAssertEqual(try JSONDecoder().decode(UsageRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testInterruptedReplyDoesNotPresentInitialUsageAsFinal() {
        let id = UUID(), supplier = UUID()
        let partial = UsageRecord(id: id, profileID: supplier, model: "claude",
            usage: TokenUsage(input: 35, output: 1), estimatedOutput: 50)
        XCTAssertEqual(partial.usage?.totalTokens, 36)
        XCTAssertEqual(partial.estimatedUnreportedOutput, 49)
        let complete = UsageRecord(id: id, profileID: supplier, model: "claude",
            usage: TokenUsage(input: 35, output: 42), estimatedOutput: 50, usageIsFinal: true)
        XCTAssertEqual(complete.estimatedUnreportedOutput, 0)
    }
}
