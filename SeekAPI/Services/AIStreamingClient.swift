import Foundation
import SeekCore

/// API credentials are sent only to the configured HTTPS origin. Redirects are rejected.
final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor AIStreamingClient {
    struct GeneratedReply: Sendable {
        var attachments: [ChatAttachment]
        var text: String
        var usage: TokenUsage?
    }
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration, delegate: RedirectPolicy(), delegateQueue: nil)
    }

    func stream(profile: APIProfile, key: String, messages: [ChatMessage],
                onDelta: @escaping @MainActor @Sendable (ReplyDelta) -> Void) async throws {
        let attachments = try await AttachmentStore.shared.files(messages)
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".request.json")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let request = try RequestBuilder.chat(profile: profile, key: key, messages: messages,
                                             attachmentFiles: attachments, bodyFile: bodyFile)
        let upload = FileUploadStream()
        defer { upload.cancel() }
        var http: HTTPURLResponse?
        var responseBody = Data()
        var completeJSON = false
        var parser = SSEParser()
        var pending = ReplyDelta()
        var hasContent = false
        var finished = false
        var done = false
        var lastFlush = ContinuousClock.now

        func consume(_ events: [SSEEvent]) throws {
            for event in events {
                if event.data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]" { done = true }
                let delta = try ResponseDecoder.delta(event, provider: profile.provider)
                pending.text += delta.text
                pending.reasoning += delta.reasoning
                if let usage = delta.usage {
                    var combined = pending.usage ?? TokenUsage()
                    combined.merge(usage)
                    pending.usage = combined
                }
                hasContent = hasContent || !delta.text.isEmpty || !delta.reasoning.isEmpty
                finished = finished || delta.isFinished
            }
        }

        try await withTaskCancellationHandler {
            for try await event in upload.start(request, file: bodyFile) {
                try Task.checkCancellation()
                switch event {
                case .response(let response):
                    http = response
                    completeJSON = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("application/json") == true
                case .data(let data):
                    guard let http else { throw APIError.malformedResponse }
                    if !(200...299).contains(http.statusCode) {
                        responseBody.append(data.prefix(max(0, 65_536 - responseBody.count)))
                        if responseBody.count >= 65_536 { throw ResponseDecoder.httpError(responseBody, status: http.statusCode) }
                        continue
                    }
                    if completeJSON {
                        guard responseBody.count + data.count <= 2_097_152 else { throw APIError.streamTooLarge }
                        responseBody.append(data); continue
                    }
                    try consume(parser.append(data))
                }
                let now = ContinuousClock.now
                if finished || lastFlush.duration(to: now) >= .milliseconds(40) {
                    if !pending.text.isEmpty || !pending.reasoning.isEmpty || pending.usage != nil {
                        await onDelta(pending)
                        pending = ReplyDelta()
                    }
                    lastFlush = now
                }
                // OpenAI sends a usage-only chunk after finish_reason. Read through [DONE].
                if done || (finished && profile.provider == .claude) { break }
            }
        } onCancel: { upload.cancel() }
        try Task.checkCancellation()
        guard let http else { throw APIError.malformedResponse }
        guard (200...299).contains(http.statusCode) else { throw ResponseDecoder.httpError(responseBody, status: http.statusCode) }
        if completeJSON {
            guard let text = String(data: responseBody, encoding: .utf8) else { throw APIError.malformedResponse }
            let delta = try ResponseDecoder.delta(SSEEvent(data: text), provider: profile.provider)
            guard !delta.text.isEmpty || !delta.reasoning.isEmpty else { throw APIError.emptyReply }
            await onDelta(delta); return
        }
        try consume(parser.finish())
        if !pending.text.isEmpty || !pending.reasoning.isEmpty || pending.usage != nil { await onDelta(pending) }
        guard hasContent else { throw APIError.emptyReply }
        // A disconnected stream must never silently present a partial answer as complete.
        guard finished else { throw APIError.provider("连接提前断开，已保留收到的内容。请重新生成。") }
    }

    func generateImage(profile: APIProfile, key: String, prompt: String, attachments: [ChatAttachment] = []) async throws -> GeneratedReply {
        let bodyFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".image-request.json")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        let references = try await AttachmentStore.shared.files([ChatMessage(role: .user, content: prompt, attachments: attachments)])
        let request = try ImageGenerationAPI.request(profile: profile, key: key, prompt: prompt,
            attachments: attachments, attachmentFiles: references, bodyFile: bodyFile)
        let upload = FileUploadStream()
        defer { upload.cancel() }
        var response: HTTPURLResponse?
        var data = Data()
        try await withTaskCancellationHandler {
            for try await event in upload.start(request, file: bodyFile) {
                try Task.checkCancellation()
                switch event {
                case .response(let http): response = http
                case .data(let bytes):
                    guard let response else { throw APIError.malformedResponse }
                    let limit = (200...299).contains(response.statusCode) ? 192_000_000 : 65_536
                    guard data.count + bytes.count <= limit else {
                        if !(200...299).contains(response.statusCode) { throw ResponseDecoder.httpError(data, status: response.statusCode) }
                        throw APIError.provider("生图响应超过大小上限，请降低分辨率后重试。")
                    }
                    data.append(bytes)
                }
            }
        } onCancel: { upload.cancel() }
        guard let response else { throw APIError.malformedResponse }
        guard (200...299).contains(response.statusCode) else { throw ResponseDecoder.httpError(data, status: response.statusCode) }
        try Task.checkCancellation()
        let result = try ImageGenerationAPI.decode(data, provider: profile.provider, format: profile.imageSettings.format)
        data = Data()
        var saved: [ChatAttachment] = []
        do {
            for image in result.images {
                try Task.checkCancellation()
                let bytes: Data
                if let embedded = image.data { bytes = embedded }
                else if let url = image.url {
                    // Signed CDN URLs are fetched by a new GET request. Never
                    // copy the supplier's API authentication to a remote image.
                    var download = URLRequest(url: url, timeoutInterval: 120)
                    download.setValue("image/*", forHTTPHeaderField: "Accept")
                    let (file, http) = try await session.download(for: download)
                    defer { try? FileManager.default.removeItem(at: file) }
                    guard let http = http as? HTTPURLResponse, (200...299).contains(http.statusCode),
                          try AttachmentFileIO.size(file, limit: 134_217_728) > 0 else {
                        throw APIError.provider("生成图片的下载地址已失效或文件过大，请重试。")
                    }
                    bytes = try Data(contentsOf: file, options: .mappedIfSafe)
                } else { throw APIError.malformedResponse }
                let item = try await AttachmentStore.shared.importGeneratedImage(bytes, settings: profile.imageSettings,
                    convert: profile.provider == .gemini)
                saved.append(item)
            }
            try Task.checkCancellation()
            return GeneratedReply(attachments: saved, text: result.text, usage: result.usage)
        } catch {
            await AttachmentStore.shared.remove(saved)
            throw error
        }
    }

    func fetchBalance(profile: APIProfile, key: String, configuration: BalanceConfiguration) async throws -> String {
        let request = try RequestBuilder.balance(profile: profile, key: key, configuration: configuration)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= 1_048_576 else { throw APIError.streamTooLarge }
        }
        guard (200...299).contains(http.statusCode) else { throw ResponseDecoder.httpError(data, status: http.statusCode) }
        return try BalanceJSON.value(data, path: configuration.jsonPath)
    }

    func fetchModels(profile: APIProfile, key: String) async throws -> [String] {
        var result: [String] = []
        var page: String?
        var seenPages = Set<String>()
        repeat {
            try Task.checkCancellation()
            let request = try RequestBuilder.models(profile: profile, key: key, pageToken: page)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.malformedResponse }
            guard (200...299).contains(http.statusCode) else {
                throw ResponseDecoder.httpError(data, status: http.statusCode)
            }
            let models = try ResponseDecoder.models(data, provider: profile.provider)
            result += models.ids
            page = models.nextPage
            if let next = page, !seenPages.insert(next).inserted { throw APIError.malformedResponse }
            guard seenPages.count <= 50 else { throw APIError.provider("模型列表分页过多，请手动输入模型 ID。") }
        } while page != nil
        let ids = Array(Set(result)).sorted()
        guard !ids.isEmpty else { throw APIError.provider("接口未返回可用模型。你仍然可以手动输入模型 ID。") }
        return ids
    }
}
