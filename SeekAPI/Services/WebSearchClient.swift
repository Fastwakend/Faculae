import Foundation
import SeekCore

actor WebSearchClient {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    func search(provider: SearchProvider, key: String, query: String) async throws -> [SearchResult] {
        do {
            if provider.kind == .deepSeek, WebSearch.safeResultURL(query) != nil {
                let request = try WebSearch.fetchRequest(provider: provider, key: key, url: query)
                return [try WebSearch.fetchedPage(await response(request), url: query)]
            }
            let request = try WebSearch.request(provider: provider, key: key, query: query)
            var results = try WebSearch.results(await response(request), provider: provider)
            if provider.kind == .deepSeek {
                for i in results.indices.prefix(provider.fetchPages) where results[i].content.isEmpty {
                    try Task.checkCancellation()
                    // Search snippets remain usable if a site refuses the optional extra fetch.
                    do {
                        let request = try WebSearch.fetchRequest(provider: provider, key: key, url: results[i].url)
                        let page = try WebSearch.fetchedPage(await response(request), url: results[i].url)
                        results[i].content = page.content
                    } catch {
                        try Task.checkCancellation()
                    }
                }
            }
            return results
        } catch {
            try Task.checkCancellation()
            let message = key.isEmpty ? error.localizedDescription : error.localizedDescription.replacingOccurrences(of: key, with: "[Key]")
            throw APIError.provider("联网搜索失败：" + message)
        }
    }

    private func response(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 2_097_152 else { throw APIError.provider("搜索响应超过 2 MB，请减少结果数或关闭正文。") }
        }
        guard (200...299).contains(http.statusCode) else { throw ResponseDecoder.httpError(data, status: http.statusCode) }
        return data
    }
}
