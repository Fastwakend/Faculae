import SwiftUI
import WebKit
import Photos
import UniformTypeIdentifiers
import ImageIO
import SeekCore

enum ReplyExportFormat: String, CaseIterable {
    case txt, md, image
    var title: String {
        switch self { case .txt: return "保存为TXT文件"; case .md: return "保存为MD文件"; case .image: return "保存为图片" }
    }
    var symbol: String {
        switch self { case .txt: return "doc.plaintext"; case .md: return "doc.text"; case .image: return "photo" }
    }
}

struct ReplyExportMenu: View {
    let onSelect: (ReplyExportFormat) -> Void
    var body: some View {
        Menu {
            ForEach(ReplyExportFormat.allCases, id: \.self) { format in
                Button { onSelect(format) } label: { Label(format.title, systemImage: format.symbol) }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16)).foregroundStyle(.secondary)
                .frame(width: 40, height: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("保存回答或对话图片")
    }
}

struct ChatExportFile: Identifiable {
    let id = UUID()
    let url: URL
    static func create(extension suffix: String) throws -> ChatExportFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SeekAPIExports")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter(); formatter.dateFormat = "yyyyMMdd-HHmmss"
        return ChatExportFile(url: folder.appendingPathComponent("Faculae-" + formatter.string(from: Date()) + "." + suffix))
    }
    func remove() {
        let folder = url.deletingLastPathComponent()
        guard folder.deletingLastPathComponent().lastPathComponent == "SeekAPIExports", UUID(uuidString: folder.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }
}

struct ChatFileExportPicker: UIViewControllerRepresentable {
    let file: ChatExportFile
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [file.url], asCopy: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish() }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
    }
}

/// WebKit callbacks can arrive after cancellation, or never arrive if its
/// process stops. Complete each stage once and release the waiting UI in either case.
@MainActor
private final class ExportCallback<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?

    func wait(seconds: Int, message: String,
              start: (@escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                deadline = Task {
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self.finish(.failure(APIError.provider(message)))
                }
                start { [weak self] result in self?.finish(result) }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel(); deadline = nil
        continuation.resume(with: result)
    }
}

/// A separate, nonpersistent renderer exports the complete conversation without
/// resizing or scrolling the live chat. Full-document PDF is rasterized once to
/// a PNG with a bounded pixel budget; no screen-sized screenshot crops history.
@MainActor
final class ConversationImageExporter: NSObject, WKNavigationDelegate {
    private let assets = TranscriptAssets()
    private var web: WKWebView?
    private var loadFinish: (@MainActor @Sendable (Result<Void, Error>) -> Void)?
    private var failOperation: ((Error) -> Void)?

    func export(messages: [ChatMessage], dark: Bool, width: CGFloat, fontSize: CGFloat,
                onProgress: (String) -> Void) async throws -> ChatExportFile {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.setURLSchemeHandler(assets, forURLScheme: "seek-local")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: max(320, min(width, 780)), height: 800), configuration: config)
        self.web = web; web.navigationDelegate = self
        defer { loadFinish = nil; failOperation = nil; web.stopLoading(); web.navigationDelegate = nil; assets.cancelAll(); self.web = nil }
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownRenderer") else { throw APIError.malformedResponse }
        onProgress("正在载入图片渲染器…")
        try await awaitCallback(seconds: 20, message: "图片渲染器载入超时，请重试。") { finish in
            loadFinish = finish
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        loadFinish = nil
        try Task.checkCancellation()
        let patches: [[String: Any]] = messages.map { message in
            ["id": message.id.uuidString, "role": message.role.rawValue, "content": message.content,
             "reasoning": message.reasoning, "status": message.status.rawValue, "modelTitle": message.modelDisplayTitle,
             "logo": assets.registerLogo(for: message, dark: dark), "sourceCount": message.searchSources?.count ?? 0,
             "error": message.error ?? "", "canRegenerate": false, "imageGeneration": message.imageGenerationSettings != nil,
             "attachments": (message.attachments ?? []).map { item in
                ["id": item.id.uuidString, "name": item.name, "kind": item.kind.rawValue,
                 "size": ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file),
                 "image": assets.registerAttachment(item, maximumPixelSize: message.imageGenerationSettings == nil ? 160 : 2560)]
             }]
        }
        let payload: [String: Any] = ["conversationID": UUID().uuidString, "order": messages.map { $0.id.uuidString },
            "patches": patches, "fontSize": fontSize, "dark": dark, "showReasoning": false]
        onProgress("正在排版完整对话…")
        let result: Any = try await awaitCallback(seconds: 45, message: "对话图片排版超时，请稍后重试。") { finish in
            web.callAsyncJavaScript("return await window.prepareConversationExport(payload);",
                arguments: ["payload": payload], in: nil, in: .page, completionHandler: finish)
        }
        guard let metrics = result as? [String: Any], let height = metrics["value"] as? Double,
              height.isFinite, height > 0 else { throw APIError.malformedResponse }
        try Task.checkCancellation()
        let pdfConfig = WKPDFConfiguration()
        pdfConfig.rect = CGRect(x: 0, y: 0, width: web.bounds.width, height: height)
        onProgress("正在生成对话图片…")
        let pdf: Data = try await awaitCallback(seconds: 30, message: "对话图片生成超时，请重试。") { finish in
            web.createPDF(configuration: pdfConfig, completionHandler: finish)
        }
        try Task.checkCancellation()
        let file = try ChatExportFile.create(extension: "png")
        do {
            let raster = Task.detached(priority: .userInitiated) { try Self.rasterize(pdf, to: file.url, dark: dark) }
            try await withTaskCancellationHandler { try await raster.value } onCancel: { raster.cancel() }
            try Task.checkCancellation()
            return file
        } catch { file.remove(); throw error }
    }

    private nonisolated static func rasterize(_ data: Data, to url: URL, dark: Bool) throws {
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: data as CFData), let pdf = CGPDFDocument(provider), let page = pdf.page(at: 1) else { throw APIError.malformedResponse }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { throw APIError.malformedResponse }
        let scale = min(2, sqrt(24_000_000 / (box.width * box.height)), 32_000 / max(box.width, box.height))
        let width = max(1, Int(floor(box.width * scale))), height = max(1, Int(floor(box.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw APIError.provider("对话图片无法创建，请稍后重试。") }
        context.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
        context.translateBy(x: -box.minX, y: -box.minY); context.drawPDFPage(page)
        try Task.checkCancellation()
        guard let image = context.makeImage(), let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw APIError.malformedResponse }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
    }

    private func awaitCallback<Value>(seconds: Int, message: String,
                                     start: (@escaping @MainActor @Sendable (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        let callback = ExportCallback<Value>()
        failOperation = { [weak callback] error in callback?.finish(.failure(error)) }
        defer { failOperation = nil }
        return try await callback.wait(seconds: seconds, message: message, start: start)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        loadFinish?(.success(Void()))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) { failOperation?(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) { failOperation?(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        failOperation?(APIError.provider("图片渲染器已中断，请重试。"))
    }
}
