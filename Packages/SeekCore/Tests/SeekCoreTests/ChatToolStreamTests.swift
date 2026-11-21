import Foundation
import XCTest
@testable import SeekCore

final class ChatToolStreamTests: XCTestCase {
    func testOpenAIOnlyReturnsCallsAfterTheToolFinishReason() throws {
        var stream = ChatToolStream(provider: .openAI)
        let thinking = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"reasoning_content":"需要核实","tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":"{\"queries\":[\""}}]}}]}"#))
        XCTAssertEqual(thinking.reasoning, "需要核实")
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"冰岛人口\"]}"}}]}}]}"#))
        XCTAssertTrue(try stream.result().calls.isEmpty)

        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#))
        let result = try stream.result()
        XCTAssertEqual(result.calls, [ChatToolCall(id: "call_1", name: "web_search", argumentsJSON: #"{"queries":["冰岛人口"]}"#)])
        let message = try assistant(result)
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertTrue(message["content"] is NSNull)
        XCTAssertEqual(message["reasoning_content"] as? String, "需要核实")
        let call = try XCTUnwrap((message["tool_calls"] as? [[String: Any]])?.first)
        XCTAssertEqual(call["type"] as? String, "function")
        XCTAssertNil(call["index"])
    }

    func testOpenAITruncatedToolRequestDoesNotExecuteEvenWithDoneMarker() throws {
        var stream = ChatToolStream(provider: .openAI)
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"web_search","arguments":"{\"queries\":[\"长"}}]},"finish_reason":"length"}]}"#))
        _ = try stream.consume(SSEEvent(data: "[DONE]"))
        XCTAssertTrue(try stream.result().calls.isEmpty)
    }

    func testClaudeRestoresSignedThinkingAndCompleteToolInput() throws {
        var stream = ChatToolStream(provider: .claude)
        let events = [
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"核实出处"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed-thought"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_search","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"queries\":["}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"official source\"]}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
        ]
        for data in events { _ = try stream.consume(SSEEvent(data: data)) }
        XCTAssertTrue(try stream.result().calls.isEmpty)

        _ = try stream.consume(SSEEvent(data: #"{"type":"message_stop"}"#))
        let result = try stream.result()
        XCTAssertEqual(result.calls, [ChatToolCall(id: "toolu_1", name: "web_search", argumentsJSON: #"{"queries":["official source"]}"#)])
        let blocks = try XCTUnwrap(try assistant(result)["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["thinking"] as? String, "核实出处")
        XCTAssertEqual(blocks.first?["signature"] as? String, "signed-thought")
        XCTAssertEqual((blocks.last?["input"] as? [String: [String]])?["queries"], ["official source"])
    }

    func testGeminiPreservesThoughtSignatureAndKeepsSyntheticIDOutOfMessage() throws {
        var stream = ChatToolStream(provider: .gemini)
        _ = try stream.consume(SSEEvent(data: #"{"candidates":[{"content":{"role":"model","parts":[{"thought":true,"text":"lookup"},{"functionCall":{"name":"web_search","args":{"queries":["first"]}},"thoughtSignature":"abc"}]}}]}"#))
        XCTAssertTrue(try stream.result().calls.isEmpty)
        _ = try stream.consume(SSEEvent(data: #"{"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"id":"provider-call","name":"web_search","args":{"queries":["second"]}}}]},"finishReason":"STOP"}]}"#))
        let usageOnly = try stream.consume(SSEEvent(data: #"{"candidates":[],"usageMetadata":{"promptTokenCount":95,"candidatesTokenCount":10,"totalTokenCount":105}}"#))
        XCTAssertEqual(usageOnly.usage?.total, 105)
        let result = try stream.result()
        XCTAssertEqual(result.calls.count, 2)
        XCTAssertNotEqual(result.calls.first?.id, result.calls.last?.id)
        XCTAssertEqual(result.calls.last?.id, "provider-call")
        let message = try assistant(result)
        XCTAssertEqual(message["role"] as? String, "model")
        let parts = try XCTUnwrap(message["parts"] as? [[String: Any]])
        XCTAssertEqual(parts[1]["thoughtSignature"] as? String, "abc")
        XCTAssertNil((parts[1]["functionCall"] as? [String: Any])?["id"])
    }

    func testGeminiMalformedOrPartialArgumentsNeverBecomeToolCalls() throws {
        let parts = [
            #"{"functionCall":{"name":"web_search","args":"bad"}}"#,
            #"{"functionCall":{"name":"web_search","willContinue":true,"partialArgs":[{"jsonPath":"$.queries","stringValue":"partial"}]}}"#,
        ]
        for part in parts {
            var stream = ChatToolStream(provider: .gemini)
            _ = try stream.consume(SSEEvent(data: #"{"candidates":[{"content":{"parts":["# + part + #"]},"finishReason":"STOP"}]}"#))
            XCTAssertThrowsError(try stream.result()) { error in
                XCTAssertEqual(error as? APIError, .malformedResponse)
            }
        }
    }

    func testDeepSeekHostedEventsAreDeduplicatedAndCitationsComeFromFinalChunk() throws {
        var stream = ChatToolStream(provider: .openAI)
        let start = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{},"server_tool_event":{"type":"call_started","step":0,"call":{"id":"srv_1","type":"deepseek_web_search","action":{"type":"search","queries":["冰岛人口"]}}}}]}"#))
        XCTAssertEqual(start.hostedSearchEvents, [.started(id: "srv_1", queries: ["冰岛人口"])])
        let finish = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{},"server_tool_event":{"type":"call_completed","step":0,"call":{"id":"srv_1","type":"deepseek_web_search","status":"completed","sources":[{"type":"url","url":"https://example.com/is","title":"Population","published_at":"2026-01-01"}]}}}]}"#))
        XCTAssertEqual(finish.hostedSearchEvents, [.finished(id: "srv_1", sources: [
            SearchResult(title: "Population", url: "https://example.com/is", publishedDate: "2026-01-01")
        ], failed: false)])
        let final = try stream.consume(SSEEvent(data: #"{"choices":[{"finish_reason":"stop","delta":{"server_tool_calls":[{"index":0,"calls":[{"id":"srv_1","type":"deepseek_web_search","action":{"type":"search","queries":["冰岛人口"]},"status":"completed"},{"id":"srv_2","type":"deepseek_read_url","action":{"type":"read_link","url":"https://example.com/file"},"status":"failed","error":{"code":"unavailable"}}]}],"annotations":[{"type":"url_citation","url_citation":{"url":"https://example.com/is","title":"Population","start_index":2,"end_index":7}}]}}]}"#))
        XCTAssertEqual(final.hostedSearchEvents, [
            .started(id: "srv_2", queries: ["https://example.com/file"]),
            .finished(id: "srv_2", sources: [], failed: true)
        ])
        XCTAssertEqual(final.hostedCitations, [
            HostedSearchCitation(url: "https://example.com/is", title: "Population", startIndex: 2, endIndex: 7)
        ])
        XCTAssertTrue(try stream.result().calls.isEmpty)
        XCTAssertNil(try stream.result().hostedHistoryJSON)
    }

    func testDeepSeekHostedHistoryKeepsOriginalSignedStepsForFollowUps() throws {
        let steps = #"{"index":0,"reasoning_content":"Read the link.","calls":[{"id":"srv_read","type":"deepseek_read_url","kind":"read_link","action":{"type":"read_link","url":"https://example.com/entry"},"status":"completed","signature":"signed-page","page":{"url":"https://example.com/entry","title":"Entry"}}]},{"index":1,"reasoning_content":"Verify the result.","calls":[{"id":"srv_search","type":"deepseek_web_search","kind":"deep_search","status":"completed","sources":[{"url":"https://example.com/other","title":"Independent source"}]}]}"#

        var stream = ChatToolStream(provider: .openAI)
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"reasoning_content":"Read the link."}}]}"#))
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{},"server_tool_event":{"type":"step_reasoning_done","step":0}}]}"#))
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"reasoning_content":"Verify the result."}}]}"#))
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{},"server_tool_event":{"type":"step_reasoning_done","step":1}}]}"#))
        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"reasoning_content":"Ready.","content":"原文内容"},"finish_reason":null}]}"#))
        XCTAssertNil(try stream.result().hostedHistoryJSON)

        _ = try stream.consume(SSEEvent(data: #"{"choices":[{"delta":{"server_tool_calls":["# + steps + #"]},"finish_reason":"stop"}]}"#))
        let history = try XCTUnwrap(try stream.result().hostedHistoryJSON)
        let message = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(history.utf8)) as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(message["content"] as? String, "原文内容")
        XCTAssertEqual(message["reasoning_content"] as? String, "Ready.")
        let actual = try XCTUnwrap(message["server_tool_calls"] as? NSArray)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(("[" + steps + "]").utf8)) as? NSArray)
        XCTAssertEqual(actual, expected)

        var complete = ChatToolStream(provider: .openAI)
        _ = try complete.consume(SSEEvent(data: #"{"choices":[{"message":{"role":"assistant","content":"原文内容","reasoning_content":"Ready.","server_tool_calls":["# + steps + #"]},"finish_reason":"stop"}]}"#))
        XCTAssertEqual(try complete.result().hostedHistoryJSON, history)

        var truncated = ChatToolStream(provider: .openAI)
        _ = try truncated.consume(SSEEvent(data: #"{"choices":[{"delta":{"server_tool_calls":["# + steps + #"]},"finish_reason":"length"}]}"#))
        XCTAssertNil(try truncated.result().hostedHistoryJSON)
    }

    private func assistant(_ response: ChatToolResponse) throws -> [String: Any] {
        let json = try XCTUnwrap(response.assistantJSON)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }
}
