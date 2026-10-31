import XCTest
@testable import SeekCore

final class WebSearchTests: XCTestCase {
    func testDeepSeekOfficialSearchAndFetchRequests() throws {
        var provider = SearchProvider(); provider.count = 7
        let request = try WebSearch.request(provider: provider, key: "test-key", query: String(repeating: "中", count: 150))
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, String(repeating: "中", count: 128))
        XCTAssertEqual(body["count"] as? Int, 7); XCTAssertEqual(body["need_content"] as? Bool, true)
        let fetch = try WebSearch.fetchRequest(provider: provider, key: "test-key", url: "https://example.com/a?q=中文")
        XCTAssertEqual(fetch.url?.absoluteString, "https://api.deepseek.com/v1/tools/fetch")
        XCTAssertEqual(try (JSONSerialization.jsonObject(with: fetch.httpBody!) as? [String: String])?["url"], "https://example.com/a?q=中文")
        XCTAssertThrowsError(try WebSearch.fetchRequest(provider: provider, key: "test-key", url: "file:///secret"))
    }
    func testAllGenericProviderRequestsAndResults() throws {
        for kind in SearchProviderKind.allCases where kind != .custom {
            let provider = SearchProvider(kind: kind)
            let request = try WebSearch.request(provider: provider, key: "key", query: "quoted \"query\" & 中文")
            XCTAssertEqual(request.httpMethod, [.brave, .searxng].contains(kind) ? "GET" : "POST")
            XCTAssertFalse(request.url!.absoluteString.contains("key"))
            let json: String
            switch kind {
            case .brave: json = #"{"web":{"results":[{"title":"Title","url":"https://a.test","description":"Brave"}]}}"#
            case .serper: json = #"{"organic":[{"title":"Title","link":"https://a.test","snippet":"Serper"}]}"#
            default: json = #"{"results":[{"title":"Title","url":"https://a.test","summary":"Summary","content":"Page"}]}"#
            }
            let results = try WebSearch.results(Data(json.utf8), provider: provider)
            XCTAssertEqual(results.count, 1); XCTAssertEqual(results[0].title, "Title")
        }
    }
    func testCustomJSONInterpolationAndNestedPaths() throws {
        var provider = SearchProvider(kind: .custom)
        provider.bodyTemplate = #"{"input":{"query":"{{query}}"},"limit":3}"#
        provider.resultsPath = "/data/items"; provider.titlePath = "meta.title"
        let query = "a\"},\"bad\":true 中文"
        let request = try WebSearch.request(provider: provider, key: "custom", query: query)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual((body["input"] as? [String: String])?["query"], query)
        XCTAssertNil(body["bad"])
        let data = Data(#"{"data":{"items":[{"meta":{"title":"Custom"},"url":"https://a.test","snippet":"Text"}]}}"#.utf8)
        XCTAssertEqual(try WebSearch.results(data, provider: provider).first?.title, "Custom")
        provider.method = "GET"; provider.queryParameter = "search"
        XCTAssertEqual(URLComponents(url: try WebSearch.request(provider: provider, key: "", query: query).url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, query)
    }
    func testUnsafeSourcesDeduplicateAndContextBoundaries() throws {
        let data = Data(#"{"results":[{"title":"A","url":"javascript:alert(1)"},{"title":"B","url":"https://user:pass@a.test"},{"title":"C","url":"https://a.test","summary":"Useful"},{"title":"D","url":"https://a.test"}]}"#.utf8)
        let results = try WebSearch.results(data, provider: SearchProvider())
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(WebSearch.context(results).contains("[1] C"))
        let saved = try JSONDecoder().decode(SearchProvider.self, from: JSONEncoder().encode(SearchProvider()))
        XCTAssertEqual(saved.kind, .deepSeek)
        XCTAssertFalse(String(data: try JSONEncoder().encode(saved), encoding: .utf8)!.contains("test-key"))
        var invalid = SearchProvider(); invalid.endpoint = "http://a.test"
        XCTAssertThrowsError(try WebSearch.request(provider: invalid, key: "key", query: "query"))
        XCTAssertThrowsError(try WebSearch.request(provider: SearchProvider(), key: "key\nInjected", query: "query"))
    }
    func testSourceMetadataSurvivesHistoryRoundTripAndOldMessagesDecode() throws {
        var message = ChatMessage(role: .assistant, content: "Answer")
        message.searchSources = [SearchResult(title: "Title", url: "https://example.com", snippet: "Summary", siteName: "Example", publishedDate: "2026-10-30")]
        message.searchProviderName = "DeepSeek"
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.searchSources, message.searchSources)
        XCTAssertEqual(decoded.searchProviderName, "DeepSeek")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        old.removeValue(forKey: "searchSources"); old.removeValue(forKey: "searchProviderName")
        XCTAssertNil(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: old)).searchSources)
    }
}
