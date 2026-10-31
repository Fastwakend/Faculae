import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ModelType: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, imageGeneration
    public var id: String { rawValue }
    public var title: String { self == .chat ? "对话模型" : "图像生成" }
}

public struct ImageGenerationSettings: Codable, Equatable, Sendable {
    public enum Resolution: String, Codable, CaseIterable, Sendable { case oneK = "1K", twoK = "2K", fourK = "4K" }
    public enum Quality: String, Codable, CaseIterable, Sendable { case auto, low, medium, high }
    public enum Format: String, Codable, CaseIterable, Sendable {
        case png, jpeg, webp
        public var mimeType: String { "image/" + rawValue }
    }
    public enum Moderation: String, Codable, CaseIterable, Sendable { case auto, low }
    public static let ratios = ["1:1", "3:2", "2:3", "16:9", "9:16", "4:3", "3:4", "21:9"]
    public var resolution: Resolution = .oneK
    public var aspectRatio = "1:1"
    public var customRatio = "1:1"
    public var quality: Quality = .auto
    public var format: Format = .png
    public var moderation: Moderation = .auto
    public var transparentBackground = false
    /// User-facing compression amount: 0 = no extra compression, 100 = maximum.
    public var compression: Int?
    public init() {}

    public var requestedRatio: String { aspectRatio == "custom" ? customRatio : aspectRatio }
    public func normalizedRatio() throws -> (width: Double, height: Double, title: String) {
        let parts = requestedRatio.replacingOccurrences(of: "：", with: ":").split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let w = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let h = Double(parts[1].trimmingCharacters(in: .whitespaces)), w.isFinite, h.isFinite,
              w > 0, h > 0, w <= 100_000, h <= 100_000, (0.125...8).contains(w / h) else {
            throw APIError.provider("图像比例请填写两个正数，例如 16:9；长宽比须在 1:8 至 8:1 之间。")
        }
        if let preset = (Self.ratios + ["1:4", "4:1", "1:8", "8:1", "4:5", "5:4"]).first(where: {
            let p = $0.split(separator: ":").compactMap { Double($0) }; return abs(p[0] / p[1] - w / h) < 0.000001
        }) { return (w, h, preset) }
        return (w, h, "\(w.formatted(.number.grouping(.never))) : \(h.formatted(.number.grouping(.never)))".replacingOccurrences(of: " ", with: ""))
    }

    public func validate(provider: APIProvider) throws {
        let ratio = try normalizedRatio()
        guard compression.map({ (0...100).contains($0) }) ?? true else {
            throw APIError.provider("压缩率须为 0–100 的整数，也可以留空。")
        }
        if provider == .openAI, !(1.0 / 3...3).contains(ratio.width / ratio.height) {
            throw APIError.provider("OpenAI 生图接口的图像比例须在 1:3 至 3:1 之间。")
        }
        if provider == .gemini, !(Self.ratios + ["1:4", "4:1", "1:8", "8:1", "4:5", "5:4"]).contains(ratio.title) {
            throw APIError.provider("Gemini 原生接口不支持此自定义比例，请使用支持的比例，例如 1:1、3:2 或 16:9。")
        }
        guard provider != .claude else { throw APIError.provider("Claude 原生协议不提供图像生成接口，请使用 OpenAI 兼容或 Gemini 协议。") }
    }

    /// OpenAI custom dimensions: a 1K/2K/4K pixel budget, 16px alignment,
    /// maximum 3840px edge and maximum 8,294,400 pixels. No silent square crop.
    public func openAISize() throws -> String {
        try validate(provider: .openAI)
        let ratio = try normalizedRatio(); let r = ratio.width / ratio.height
        let pixels: Double = resolution == .oneK ? 1_048_576 : (resolution == .twoK ? 4_194_304 : 8_294_400)
        var width = sqrt(pixels * r), height = sqrt(pixels / r)
        let scale = min(1, 3840 / max(width, height)); width *= scale; height *= scale
        let w = max(16, Int(width / 16) * 16), h = max(16, Int(height / 16) * 16)
        return "\(w)x\(h)"
    }

    public var geminiPreferences: String {
        let transparency = format == .png && transparentBackground
        return "\n\n[Image preferences] Resolution: \(resolution.rawValue); aspect ratio: \(requestedRatio); quality: \(quality.rawValue); output format: \(format.rawValue); moderation: \(moderation.rawValue); transparent background: \(transparency); compression amount: \(compression.map(String.init) ?? "0")%. Generate an image for the prompt above."
    }
}

public enum ImageGenerationAPI {
    public static func validateReferences(_ attachments: [ChatAttachment]) throws {
        guard attachments.count <= AttachmentLimits.count else { throw APIError.provider("每次最多添加 6 个参考附件。") }
        guard attachments.allSatisfy({ $0.kind == .image && ["image/jpeg", "image/png", "image/webp"].contains($0.mimeType) }) else {
            throw APIError.provider("图像生成的参考附件请使用图片；文档请先转换为图片后添加。")
        }
    }

    public static func request(profile: APIProfile, key: String, prompt: String,
                               attachments: [ChatAttachment] = [], attachmentFiles: [UUID: URL] = [:],
                               bodyFile: URL? = nil) throws -> URLRequest {
        try RequestBuilder.validate(profile)
        try validateReferences(attachments)
        guard profile.selectedModel.effectiveType == .imageGeneration else { throw APIError.invalidModel }
        let settings = profile.imageSettings
        try settings.validate(provider: profile.provider)
        var prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if prompt.isEmpty && !attachments.isEmpty { prompt = "请参考上传的图片生成图像。" }
        guard !prompt.isEmpty else { throw APIError.provider("请输入用于生成图像的提示词或添加参考图。") }
        for image in attachments {
            guard let file = attachmentFiles[image.id] else { throw APIError.provider("参考图读取失败，请重新添加。") }
            _ = try AttachmentFileIO.size(file)
        }
        var url = try RequestBuilder.baseURL(profile)
        var body: [String: Any]
        switch profile.provider {
        case .openAI:
            url.appendPathComponent(attachments.isEmpty ? "images/generations" : "images/edits")
            let combined = profile.systemPrompt.isEmpty ? prompt : profile.systemPrompt + "\n\n" + prompt
            body = ["model": profile.model, "prompt": combined, "n": 1, "size": try settings.openAISize(),
                    "quality": settings.quality.rawValue, "output_format": settings.format.rawValue,
                    "moderation": settings.moderation.rawValue,
                    "background": settings.format == .png && settings.transparentBackground ? "transparent" : "opaque"]
            if settings.format != .png, let compression = settings.compression {
                // The API's default 100 is maximum encoder quality. Present the
                // inverse amount in the UI so 0% means no extra compression.
                body["output_compression"] = 100 - compression
            }
        case .gemini:
            let model = profile.model.hasPrefix("models/") ? String(profile.model.dropFirst(7)) : profile.model
            url.appendPathComponent("models/" + model + ":generateContent")
            body = ["contents": [["role": "user", "parts": [["text": prompt + settings.geminiPreferences]]]],
                    "generationConfig": ["responseModalities": ["TEXT", "IMAGE"],
                        "imageConfig": ["aspectRatio": try settings.normalizedRatio().title, "imageSize": settings.resolution.rawValue]]]
            if !attachments.isEmpty {
                let parts: [[String: Any]] = [["text": prompt + settings.geminiPreferences]] + attachments.map { image in
                    ["inlineData": ["mimeType": image.mimeType,
                        "data": JSONFileString(url: attachmentFiles[image.id]!, encoding: .base64)]]
                }
                body["contents"] = [["role": "user", "parts": parts]]
            }
            if !profile.systemPrompt.isEmpty { body["systemInstruction"] = ["parts": [["text": profile.systemPrompt]]] }
            if settings.moderation == .low {
                body["safetySettings"] = ["HARASSMENT", "HATE_SPEECH", "SEXUALLY_EXPLICIT", "DANGEROUS_CONTENT"].map {
                    ["category": "HARM_CATEGORY_" + $0, "threshold": "BLOCK_ONLY_HIGH"]
                }
            }
        case .claude: throw APIError.invalidModel
        }
        var request = try RequestBuilder.authorizedRequest(url: url, profile: profile, key: key)
        request.httpMethod = "POST"; request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if profile.provider == .openAI && !attachments.isEmpty {
            guard let bodyFile else { throw APIError.invalidParameters }
            let boundary = "SeekAPI-" + UUID().uuidString
            request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
            try MultipartFileWriter.write(fields: body, images: attachments, files: attachmentFiles, boundary: boundary, to: bodyFile)
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let bodyFile { try FileJSONWriter.write(body, to: bodyFile) }
            else {
                guard attachments.isEmpty else { throw APIError.invalidParameters }
                request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            }
        }
        return request
    }

    public struct Image: Sendable, Equatable {
        public var data: Data?
        public var url: URL?
        public var mimeType: String
    }
    public struct Response: Sendable {
        public var images: [Image]
        public var text: String
        public var usage: TokenUsage?
    }

    public static func decode(_ data: Data, provider: APIProvider, format: ImageGenerationSettings.Format) throws -> Response {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw APIError.malformedResponse }
        if let error = root["error"] as? [String: Any] { throw APIError.provider(error["message"] as? String ?? "图像生成失败。") }
        var images: [Image] = [], texts: [String] = []
        func add(_ object: [String: Any], base64: String, mime: String) throws {
            guard images.count < 6, let encoded = object[base64] as? String, !encoded.isEmpty,
                  encoded.utf8.count <= 180_000_000, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty else {
                throw APIError.malformedResponse
            }
            images.append(Image(data: bytes, url: nil, mimeType: mime))
        }
        if provider == .openAI {
            for item in root["data"] as? [[String: Any]] ?? [] {
                if item["b64_json"] != nil { try add(item, base64: "b64_json", mime: format.mimeType) }
                else if let raw = item["url"] as? String, let parts = URLComponents(string: raw),
                        parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
                        let url = parts.url, images.count < 6 {
                    images.append(Image(data: nil, url: url, mimeType: format.mimeType))
                } else { throw APIError.malformedResponse }
            }
        } else if provider == .gemini {
            if let feedback = root["promptFeedback"] as? [String: Any], let reason = feedback["blockReason"] as? String {
                throw APIError.provider("图像提示词被服务拦截：" + reason)
            }
            for candidate in (root["candidates"] as? [[String: Any]] ?? []).prefix(1) {
                for part in (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? [] {
                    if part["thought"] as? Bool == true { continue }
                    if let image = (part["inlineData"] ?? part["inline_data"]) as? [String: Any] {
                        let mime = (image["mimeType"] ?? image["mime_type"]) as? String ?? "image/png"
                        guard ["image/png", "image/jpeg", "image/webp"].contains(mime) else { throw APIError.malformedResponse }
                        try add(image, base64: "data", mime: mime)
                    } else if let text = part["text"] as? String { texts.append(text) }
                }
            }
        }
        guard !images.isEmpty else {
            throw APIError.provider(texts.isEmpty ? "模型没有返回图片，请检查生图权限、模型类型和参数。" : texts.joined(separator: "\n"))
        }
        var usage = TokenUsage.decode(root, provider: provider)
        if provider == .openAI, let u = root["usage"] as? [String: Any] {
            usage = TokenUsage.decode(["usage": ["prompt_tokens": u["input_tokens"] as Any,
                "completion_tokens": u["output_tokens"] as Any, "total_tokens": u["total_tokens"] as Any]], provider: .openAI)
        }
        return Response(images: images, text: texts.joined(separator: "\n\n"), usage: usage)
    }
}
