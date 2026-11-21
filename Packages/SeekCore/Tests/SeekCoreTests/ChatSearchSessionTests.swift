import Foundation
import XCTest
@testable import SeekCore

final class ChatSearchSessionTests: XCTestCase {
    @MainActor
    func testDirectAnswerUsesOneModelRequestWithoutLookup() async throws {
        var requests: [ChatWebTools] = []
        let sources = try await ChatSearchSession.run(stream: { tools, turns in
            requests.append(tools)
            XCTAssertTrue(turns.isEmpty)
            return ChatToolResponse()
        }, lookup: { _ in
            XCTFail("A reply with no tool call must not start a lookup")
            return []
        }, onProgress: { _ in
            XCTFail("A reply with no tool call must not show search progress")
        })
        XCTAssertEqual(requests, [.client])
        XCTAssertTrue(sources.items.isEmpty)
    }

    @MainActor
    func testSearchFollowsModelQueriesAndReturnsBoundedEvidenceForFinalAnswer() async throws {
        let initial = ChatToolCall(id: "call1", name: "web_search",
                                   argumentsJSON: #"{"queries":["exact query","  exact query  ","timeout","third","over budget"]}"#)
        let followUp = ChatToolCall(id: "call2", name: "web_search",
                                    argumentsJSON: #"{"queries":["exact query","follow up"]}"#)
        var requests: [ChatWebTools] = []
        var queries: [String] = []
        var failures: [Bool] = []
        let sources = try await ChatSearchSession.run(stream: { tools, turns in
            requests.append(tools)
            switch turns.count {
            case 0: return ChatToolResponse(assistantJSON: "{}", calls: [initial])
            case 1:
                let result = try XCTUnwrap(turns.first?.results.first)
                XCTAssertEqual(result.call.id, "call1")
                XCTAssertFalse(result.isError)
                XCTAssertTrue(result.content.contains("search_failed"))
                XCTAssertTrue(result.content.contains("first evidence"))
                return ChatToolResponse(assistantJSON: "{}", calls: [followUp])
            default:
                let result = try XCTUnwrap(turns.last?.results.first)
                XCTAssertTrue(result.content.contains("\"id\":2"))
                return ChatToolResponse()
            }
        }, lookup: { query in
            queries.append(query)
            if query == "timeout" { throw APIError.provider("offline") }
            let followUp = query == "follow up"
            return [SearchResult(title: "Source", url: followUp ? "https://example.com/2" : "https://example.com/1",
                                 snippet: followUp ? "further evidence" : "first evidence")]
        }, onProgress: { event in
            if case let .searched(_, failed) = event { failures.append(failed) }
        })
        XCTAssertEqual(requests, [.client, .client, .clientFinal])
        XCTAssertEqual(queries, ["exact query", "timeout", "third", "follow up"])
        XCTAssertEqual(failures, [true, false])
        XCTAssertEqual(sources.items.count, 2)
        XCTAssertEqual(sources.linkingReferences(in: "事实 [来源1] [来源9]"),
                       "事实 [1](<https://example.com/1>) ")
    }

    @MainActor
    func testFollowUpSearchCanAddSourcesWhenFirstRoundFillsItsBudget() async throws {
        struct Evidence: Decodable {
            struct Source: Decodable {
                let id: Int
                let url: String
            }
            let results: [Source]
            let status: String
        }
        let initial = ChatToolCall(id: "initial", name: "web_search",
                                   argumentsJSON: #"{"queries":["one","two","three"]}"#)
        let followUp = ChatToolCall(id: "follow-up", name: "web_search",
                                    argumentsJSON: #"{"queries":["follow-up"]}"#)
        let sources = try await ChatSearchSession.run(stream: { tools, turns in
            switch turns.count {
            case 0:
                return ChatToolResponse(assistantJSON: "{}", calls: [initial])
            case 1:
                let result = try XCTUnwrap(turns.first?.results.first)
                let evidence = try JSONDecoder().decode(Evidence.self, from: Data(result.content.utf8))
                XCTAssertEqual(evidence.results.map(\.id), Array(1...10))
                return ChatToolResponse(assistantJSON: "{}", calls: [followUp])
            default:
                XCTAssertEqual(tools, .clientFinal)
                let result = try XCTUnwrap(turns.last?.results.first)
                let evidence = try JSONDecoder().decode(Evidence.self, from: Data(result.content.utf8))
                XCTAssertEqual(evidence.status, "ok")
                XCTAssertEqual(evidence.results.map(\.id), Array(11...15))
                XCTAssertEqual(evidence.results.map(\.url), (1...5).map { "https://example.com/follow-up/\($0)" })
                return ChatToolResponse()
            }
        }, lookup: { query in
            (1...5).map { SearchResult(title: "Source", url: "https://example.com/\(query)/\($0)") }
        }, onProgress: { _ in })
        XCTAssertEqual(sources.items.count, 15)
    }

    @MainActor
    func testLookupCancellationEndsReplyBeforeAnotherModelRequest() async {
        let call = ChatToolCall(id: "call", name: "web_search", argumentsJSON: #"{"queries":["one","two"]}"#)
        let task = Task {
            var requests = 0
            var lookups = 0
            do {
                _ = try await ChatSearchSession.run(stream: { _, _ in
                    requests += 1
                    return ChatToolResponse(assistantJSON: "{}", calls: [call])
                }, lookup: { _ in
                    lookups += 1
                    withUnsafeCurrentTask { $0?.cancel() }
                    return []
                }, onProgress: { _ in })
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                XCTAssertEqual(requests, 1)
                XCTAssertEqual(lookups, 1)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
        await task.value
    }

    func testHostedCitationsUseUnicodeCodePointsAndDeduplicateSources() {
        var sources = ChatSearchSources()
        sources.add([SearchResult(title: "Source", url: "https://example.com/a")])
        let citation = HostedSearchCitation(url: "https://example.com/a", title: "Source", startIndex: 0, endIndex: 3)
        let invalid = HostedSearchCitation(url: "file:///private", title: "Invalid", startIndex: 0, endIndex: 2)
        XCTAssertEqual(sources.linking([citation, citation, invalid], in: "甲🇨🇳乙"),
                       "甲🇨🇳 [1](<https://example.com/a>)乙")
        XCTAssertEqual(sources.displayItems.count, 1)
    }

    func testUsageAddsRequestsAfterMergingTheirCumulativeSnapshots() {
        var first = TokenUsage(input: 10, output: 4, total: 14)
        first.merge(TokenUsage(input: 10, output: 6, total: 16))
        first.addRequest(TokenUsage(input: 20, output: 8))
        XCTAssertEqual(first, TokenUsage(input: 30, output: 14, total: 44))
    }
}
