import SwiftUI
import WebKit
import ImageIO
import UniformTypeIdentifiers
import SeekCore
import Photos

/// One persistent native scroll view owns the whole conversation. Message
/// identities and DOM nodes survive scrolling; only changed replies are patched.
@MainActor
struct ChatTranscriptView: View {
    let messages: [ChatMessage]
    let conversationID: UUID?
    let isStreaming: Bool
    let topInset: CGFloat
    let bottomInset: CGFloat
    let scrollContext: TranscriptScrollContext
    let scrollRequest: Int
    @Binding var followsStream: Bool
    let onRegenerate: () -> Void
    let onBranch: (UUID) -> Void
    @AppStorage("showReasoning") private var showReasoning = true
    @AppStorage("automaticallyScroll") private var automaticallyScroll = true
    @Environment(\.chatTextScale) private var textScale
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 16
    @State private var failed = false
    @State private var exportFile: ChatExportFile?
    @State private var exporting = false
    @State private var exportProgress = "正在准备保存…"
    @State private var exportNotice: String?
    @State private var exportWork: Task<Void, Never>?
    @State private var preview: ChatAttachment?
    @State private var sources: ReplySources?

    var body: some View {
        Group {
            if failed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.role == .user ? "你" : message.modelDisplayTitle).font(.caption)
                                ForEach((message.attachments ?? []).filter { $0.kind == .image }) { attachment in
                                    Button { preview = attachment } label: { Label("预览图片：" + attachment.name, systemImage: "photo") }
                                }
                                Text(message.content).textSelection(.enabled)
                                if let items = message.searchSources, !items.isEmpty {
                                    SearchSourcesButton(sources: items) { showSources(message.id) }
                                }
                                if message.role == .assistant, message.status != .streaming,
                                   !message.content.isEmpty || !message.reasoning.isEmpty || !(message.attachments ?? []).isEmpty {
                                    HStack(spacing: 4) {
                                        if !message.content.isEmpty {
                                        Button { handleAction("copy", id: message.id) } label: {
                                            Image(systemName: "doc.on.doc").frame(width: 40, height: 40)
                                        }
                                        }
                                        ReplyExportMenu { exportReply($0, id: message.id) }
                                        Button { handleAction("branch", id: message.id) } label: {
                                            Image(systemName: "arrow.triangle.branch").frame(width: 40, height: 40)
                                        }.accessibilityLabel("分支到新对话")
                                        if message.id == messages.last?.id && !isStreaming {
                                            Button { handleAction("regenerate", id: message.id) } label: {
                                                Image(systemName: "arrow.clockwise").frame(width: 40, height: 40)
                                            }.accessibilityLabel("重新生成")
                                        }
                                    }.font(.system(size: 16)).foregroundStyle(.secondary).buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, topInset + 24)
                    .padding(.bottom, bottomInset)
                }
            } else {
                TranscriptWebView(input: .init(messages: messages, conversationID: conversationID,
                    fontSize: bodySize * textScale, dark: colorScheme == .dark,
                    showReasoning: showReasoning, isStreaming: isStreaming,
                    topInset: topInset, bottomInset: bottomInset),
                    scrollContext: scrollContext, scrollRequest: scrollRequest,
                    automaticallyScroll: automaticallyScroll, followsStream: $followsStream,
                    failed: $failed, onAction: handleAction, onPreview: previewAttachment, onExport: exportReply)
            }
        }
        .sheet(item: $exportFile) { item in
            ChatFileExportPicker(file: item) { exportFile = nil }.onDisappear { item.remove() }
        }
        .fullScreenCover(item: $preview) { item in AttachmentImagePreview(attachment: item) }
        .sheet(item: $sources) { SearchSourcesView(reply: $0) }
        .overlay {
            if exporting {
                VStack(spacing: 14) {
                    ProgressView(exportProgress)
                    Button("取消") { exportWork?.cancel() }.buttonStyle(.plain)
                }.padding(20)
                    .seekGlass(in: RoundedRectangle(cornerRadius: 20))
            }
        }
        .alert("保存", isPresented: Binding(get: { exportNotice != nil }, set: { if !$0 { exportNotice = nil } })) {
            Button("知道了", role: .cancel) { exportNotice = nil }
        } message: { Text(exportNotice ?? "") }
        .onDisappear { exportWork?.cancel() }
    }

    private func previewAttachment(messageID: UUID, attachmentID: UUID) {
        guard let item = messages.first(where: { $0.id == messageID })?.attachments?.first(where: { $0.id == attachmentID }),
              item.kind == .image else { return }
        preview = item
    }

    private func handleAction(_ action: String, id: UUID) {
        guard let message = messages.first(where: { $0.id == id }), message.role == .assistant else { return }
        Haptics.shared.play()
        switch action {
        case "copy": UIPasteboard.general.string = message.content
        case "branch": if message.status != .streaming { onBranch(id) }
        case "regenerate":
            if message.id == messages.last?.id && !isStreaming { onRegenerate() }
        case "sources": showSources(id)
        default: break
        }
    }

    private func exportReply(_ format: ReplyExportFormat, id: UUID) {
        guard !exporting, let message = messages.first(where: { $0.id == id }), message.role == .assistant else { return }
        Haptics.shared.play()
        let snapshot = messages, dark = colorScheme == .dark
        let width = scrollContext.scrollView?.bounds.width ?? 393
        exporting = true
        exportProgress = "正在准备保存…"
        exportWork = Task {
            defer { exporting = false; exportWork = nil }
            do {
                if format == .image {
                    let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                    guard authorization == .authorized || authorization == .limited else {
                        throw APIError.provider("请在系统设置中允许 Faculae 添加照片，再保存对话图片。")
                    }
                    try Task.checkCancellation()
                    let file = try await ConversationImageExporter().export(messages: snapshot, dark: dark,
                        width: width, fontSize: bodySize * textScale,
                        onProgress: { exportProgress = $0 })
                    defer { file.remove() }
                    try Task.checkCancellation()
                    exportProgress = "正在保存到相册…"
                    _ = try await PhotoLibrarySaver.save(url: file.url, filename: file.url.lastPathComponent)
                    exportNotice = "整段对话图片已保存到系统相册。"
                } else {
                    let text = format == .md ? message.content : await plainReply(id: id, fallback: message.content)
                    try Task.checkCancellation()
                    let file = try ChatExportFile.create(extension: format.rawValue)
                    do { try Data(text.utf8).write(to: file.url, options: .atomic); exportFile = file }
                    catch { file.remove(); throw error }
                }
            } catch is CancellationError {} catch { exportNotice = error.localizedDescription }
        }
    }

    private func plainReply(id: UUID, fallback: String) async -> String {
        var ancestor: UIView? = scrollContext.scrollView
        while let view = ancestor {
            if let web = view as? WKWebView {
                let result = try? await web.callAsyncJavaScript("return window.replyPlainText(id);",
                    arguments: ["id": id.uuidString], in: nil, contentWorld: .page)
                if let text = result as? String, !text.isEmpty { return text }
                break
            }
            ancestor = view.superview
        }
        return fallback
    }

    private func showSources(_ id: UUID) {
        guard let message = messages.first(where: { $0.id == id }), let items = message.searchSources, !items.isEmpty else { return }
        sources = ReplySources(id: id, provider: message.searchProviderName ?? "联网搜索", sources: items)
    }
}

@MainActor
private final class TranscriptNativeWebView: WKWebView {
    var onViewportChange: (() -> Void)?
    private var lastViewport: CGSize = .zero
    override func layoutSubviews() {
        super.layoutSubviews()
        if lastViewport != bounds.size {
            lastViewport = bounds.size
            onViewportChange?()
        }
    }
}

@MainActor
private struct TranscriptWebView: UIViewRepresentable {
    struct Input: Equatable {
        let messages: [ChatMessage]
        let conversationID: UUID?
        let fontSize: CGFloat
        let dark: Bool
        let showReasoning: Bool
        let isStreaming: Bool
        let topInset: CGFloat
        let bottomInset: CGFloat
    }
    let input: Input
    let scrollContext: TranscriptScrollContext
    let scrollRequest: Int
    let automaticallyScroll: Bool
    @Binding var followsStream: Bool
    @Binding var failed: Bool
    let onAction: (String, UUID) -> Void
    let onPreview: (UUID, UUID) -> Void
    let onExport: (ReplyExportFormat, UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.userContentController.add(context.coordinator, name: "renderer")
        config.setURLSchemeHandler(context.coordinator.assets, forURLScheme: "seek-local")
        let view = TranscriptNativeWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.scrollView.keyboardDismissMode = .interactive
        view.scrollView.alwaysBounceVertical = true
        view.scrollView.delegate = context.coordinator
        if #available(iOS 26, *) {
            view.scrollView.topEdgeEffect.style = .soft
            view.scrollView.topEdgeEffect.isHidden = false
        }
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        context.coordinator.observeGeometry(view)
        context.coordinator.configureScroll(view)
        DispatchQueue.main.async { scrollContext.scrollView = view.scrollView }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "MarkdownRenderer") {
            context.coordinator.rendererURL = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else { DispatchQueue.main.async { failed = true } }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.configureScroll(view)
        context.coordinator.schedule(input)
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.worker?.cancel()
        coordinator.sizeObservation?.invalidate()
        (view as? TranscriptNativeWebView)?.onViewportChange = nil
        coordinator.assets.cancelAll()
        coordinator.removeSourceButtons()
        view.configuration.userContentController.removeScriptMessageHandler(forName: "renderer")
        view.scrollView.delegate = nil
        view.navigationDelegate = nil
        view.stopLoading()
        let scrollContext = coordinator.parent.scrollContext
        DispatchQueue.main.async {
            if scrollContext.scrollView === view.scrollView { scrollContext.scrollView = nil }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: TranscriptWebView
        weak var webView: WKWebView?
        var rendererURL: URL?
        var worker: Task<Void, Never>?
        var sizeObservation: NSKeyValueObservation?
        let assets = TranscriptAssets()
        private var ready = false
        private var latest: Input?
        private var rendered: Input?
        private var sent: [UUID: ChatMessage] = [:]
        private var lastScrollRequest = -1
        private var needsInitialScroll = true
        private var pendingExplicitScroll = false
        private var documentHeight: CGFloat?
        private var revision = 0
        private var committedRevision = 0
        private var syncScheduled = false
        private var sourceButtons: [UUID: UIHostingController<SearchSourcesButton>] = [:]
        private var shareButtons: [UUID: UIButton] = [:]

        init(parent: TranscriptWebView) { self.parent = parent }

        func observeGeometry(_ view: TranscriptNativeWebView) {
            view.onViewportChange = { [weak self] in self?.requestScrollSync() }
            sizeObservation = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                DispatchQueue.main.async { self?.requestScrollSync() }
            }
        }

        func configureScroll(_ view: WKWebView) {
            // Document padding owns the header/composer reservations. Native insets
            // add blank scrollable space to WebKit's minimum one-screen document.
            view.scrollView.contentInset = .zero
            view.scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: parent.input.topInset,
                left: 0, bottom: parent.input.bottomInset, right: 0)
            if lastScrollRequest != parent.scrollRequest {
                lastScrollRequest = parent.scrollRequest
                pendingExplicitScroll = true
            }
            requestScrollSync()
        }

        func schedule(_ input: Input) {
            latest = input
            guard ready, rendered != input, worker == nil else { return }
            // Throttle instead of restarting a debounce timer for every token.
            worker = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled, let next = self.latest, next != self.rendered {
                    do { try await self.apply(next) }
                    catch {
                        if !Task.isCancelled { self.parent.failed = true }
                        break
                    }
                    if next.isStreaming { try? await Task.sleep(for: .milliseconds(100)) }
                }
                self.worker = nil
            }
        }

        private func apply(_ input: Input) async throws {
            guard let webView else { return }
            let reset = rendered?.conversationID != input.conversationID || rendered == nil
            let restyle = reset || rendered?.dark != input.dark || rendered?.fontSize != input.fontSize ||
                rendered?.showReasoning != input.showReasoning || rendered?.isStreaming != input.isStreaming ||
                rendered?.messages.last?.id != input.messages.last?.id
            if reset { sent = [:]; needsInitialScroll = true; documentHeight = nil }
            revision += 1
            let applyingRevision = revision
            var patches: [[String: Any]] = []
            for message in input.messages where restyle || sent[message.id] != message {
                let logo = assets.registerLogo(for: message, dark: input.dark)
                let attachments = (message.attachments ?? []).map { item -> [String: Any] in
                    ["id": item.id.uuidString, "name": item.name,
                     "size": ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file),
                     "kind": item.kind.rawValue, "image": assets.registerAttachment(item,
                        maximumPixelSize: message.imageGenerationSettings == nil ? 160 : 1280)]
                }
                patches.append(["id": message.id.uuidString, "role": message.role.rawValue,
                    "content": message.content, "reasoning": message.reasoning, "status": message.status.rawValue,
                    "modelTitle": message.modelDisplayTitle, "logo": logo, "error": message.error ?? "",
                    "sourceCount": message.searchSources?.count ?? 0, "generationStage": message.generationStage ?? "",
                    "attachments": attachments, "imageGeneration": message.imageGenerationSettings != nil,
                    "canRegenerate": message.id == input.messages.last?.id && !input.isStreaming])
            }
            let payload: [String: Any] = ["conversationID": input.conversationID?.uuidString ?? "new",
                "patches": patches, "order": input.messages.map { $0.id.uuidString },
                "fontSize": input.fontSize, "dark": input.dark, "showReasoning": input.showReasoning,
                "topInset": input.topInset, "bottomInset": input.bottomInset, "revision": applyingRevision,
                "nativeSourceButtons": true, "nativeShareButtons": true]
            let result = try await webView.callAsyncJavaScript(
                "return await window.updateTranscript(payload);",
                arguments: ["payload": payload], in: nil, contentWorld: .page)
            sent = Dictionary(uniqueKeysWithValues: input.messages.map { ($0.id, $0) })
            rendered = input
            committedRevision = applyingRevision
            if let metrics = result as? [String: Any], let height = metrics["value"] as? Double,
               height.isFinite, height > 0 {
                documentHeight = height
                updateSourceButtons(metrics["sourceAnchors"] as? [[String: Any]] ?? [])
                updateShareButtons(metrics["shareAnchors"] as? [[String: Any]] ?? [])
            }
            requestScrollSync()
        }

        func removeSourceButtons() {
            for host in sourceButtons.values {
                host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
            }
            sourceButtons.removeAll()
            for button in shareButtons.values { button.removeFromSuperview() }
            shareButtons.removeAll()
        }

        private func updateShareButtons(_ anchors: [[String: Any]]) {
            guard let webView else { return }
            var keep = Set<UUID>()
            for anchor in anchors {
                guard let raw = anchor["id"] as? String, let id = UUID(uuidString: raw),
                      let message = rendered?.messages.first(where: { $0.id == id }), message.role == .assistant,
                      message.status != .streaming, !message.content.isEmpty,
                      let x = anchor["x"] as? Double, let y = anchor["y"] as? Double,
                      let width = anchor["width"] as? Double, let height = anchor["height"] as? Double,
                      [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { continue }
                keep.insert(id)
                let button: UIButton
                if let existing = shareButtons[id] { button = existing }
                else {
                    // The WebView draws Share with the exact same SVG box and
                    // padding as Copy. This clear native target only hosts UIMenu.
                    button = UIButton(type: .custom)
                    button.backgroundColor = .clear
                    button.accessibilityLabel = "保存回答或对话图片"
                    button.showsMenuAsPrimaryAction = true
                    button.menu = UIMenu(children: ReplyExportFormat.allCases.map { format in
                        UIAction(title: format.title, image: UIImage(systemName: format.symbol)) { [weak self] _ in self?.parent.onExport(format, id) }
                    })
                    webView.scrollView.addSubview(button); shareButtons[id] = button
                }
                button.overrideUserInterfaceStyle = rendered?.dark == true ? .dark : .light
                button.frame = CGRect(x: x, y: y, width: min(width, 60), height: min(height, 60))
            }
            for id in Array(shareButtons.keys) where !keep.contains(id) { shareButtons.removeValue(forKey: id)?.removeFromSuperview() }
        }

        private func updateSourceButtons(_ anchors: [[String: Any]]) {
            guard let webView else { return }
            let messages = rendered?.messages ?? []
            var keep = Set<UUID>()
            for anchor in anchors {
                guard let raw = anchor["id"] as? String, let id = UUID(uuidString: raw),
                      let message = messages.first(where: { $0.id == id }), let sources = message.searchSources, !sources.isEmpty,
                      let x = anchor["x"] as? Double, let y = anchor["y"] as? Double,
                      let width = anchor["width"] as? Double, let height = anchor["height"] as? Double,
                      [x, y, width, height].allSatisfy({ $0.isFinite }), width > 0, height > 0 else { continue }
                keep.insert(id)
                let content = SearchSourcesButton(sources: sources) { [weak self] in self?.parent.onAction("sources", id) }
                let host: UIHostingController<SearchSourcesButton>
                if let existing = sourceButtons[id] { host = existing; host.rootView = content }
                else {
                    host = UIHostingController(rootView: content)
                    host.safeAreaRegions = []
                    host.view.backgroundColor = .clear; host.view.isOpaque = false
                    var responder: UIResponder? = webView
                    while let next = responder, !(next is UIViewController) { responder = next.next }
                    if let owner = responder as? UIViewController { owner.addChild(host) }
                    webView.scrollView.addSubview(host.view)
                    if host.parent != nil { host.didMove(toParent: host.parent) }
                    sourceButtons[id] = host
                }
                host.overrideUserInterfaceStyle = rendered?.dark == true ? .dark : .light
                host.view.frame = CGRect(x: x, y: y, width: min(width, 210), height: min(height, 60))
            }
            for id in Array(sourceButtons.keys) where !keep.contains(id) {
                if let host = sourceButtons.removeValue(forKey: id) {
                    host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
                }
            }
        }

        private func requestScrollSync() {
            guard !syncScheduled else { return }
            syncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncScheduled = false
                self.synchronizeScroll()
            }
        }

        private func synchronizeScroll() {
            guard ready, rendered == parent.input, let height = documentHeight,
                  let scroll = webView?.scrollView, scroll.bounds.height > 0,
                  scroll.contentSize.height + 1 >= height else { return }
            let force = pendingExplicitScroll
            guard force || needsInitialScroll || (parent.automaticallyScroll && parent.followsStream) else { return }
            guard force || (!scroll.isDragging && !scroll.isDecelerating) else { return }
            if force {
                // An explicit tap must cancel momentum before setting the new offset.
                scroll.setContentOffset(scroll.contentOffset, animated: false)
                if scroll.isDragging {
                    scroll.panGestureRecognizer.isEnabled = false
                    scroll.panGestureRecognizer.isEnabled = true
                }
            }
            // Use the measured document, not WebKit's viewport-height minimum.
            let bottom = max(0, height - scroll.bounds.height)
            if abs(scroll.contentOffset.y - bottom) > 0.5 {
                scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
            pendingExplicitScroll = false
            needsInitialScroll = false
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            needsInitialScroll = false
            pendingExplicitScroll = false
            if parent.followsStream { parent.followsStream = false }
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { updateFollowing(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { updateFollowing(scrollView) }

        private func updateFollowing(_ scroll: UIScrollView) {
            let gap = (documentHeight ?? scroll.contentSize.height) - scroll.contentOffset.y - scroll.bounds.height
            let following = gap < 64
            if following != parent.followsStream { parent.followsStream = following }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                ready = true
                if let latest { schedule(latest) }
            case "layout":
                guard body["revision"] as? Int == committedRevision,
                      body["conversationID"] as? String == (rendered?.conversationID?.uuidString ?? "new"),
                      let height = body["value"] as? Double, height.isFinite, height > 0 else { return }
                documentHeight = height
                updateSourceButtons(body["sourceAnchors"] as? [[String: Any]] ?? [])
                updateShareButtons(body["shareAnchors"] as? [[String: Any]] ?? [])
                requestScrollSync()
            case "action":
                if let action = body["action"] as? String, let raw = body["id"] as? String, let id = UUID(uuidString: raw) {
                    parent.onAction(action, id)
                }
            case "attachment":
                if let raw = body["id"] as? String, let id = UUID(uuidString: raw),
                   let rawAttachment = body["attachmentID"] as? String, let attachmentID = UUID(uuidString: rawAttachment) {
                    parent.onPreview(id, attachmentID)
                }
            case "copy": if let text = body["text"] as? String { UIPasteboard.general.string = text }
            case "haptic":
                if body["category"] as? String == "card", let raw = body["id"] as? String,
                   let id = UUID(uuidString: raw), parent.input.messages.contains(where: { $0.id == id && !$0.reasoning.isEmpty }) {
                    Haptics.shared.play(.card)
                }
            case "failure": parent.failed = true
            default: break
            }
        }

        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if action.navigationType == .linkActivated {
                if ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
                decisionHandler(.cancel)
            } else if action.targetFrame?.isMainFrame == true && url == rendererURL { decisionHandler(.allow) }
            else { decisionHandler(.cancel) }
        }

        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { parent.failed = true }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) { parent.failed = true }
    }
}

/// Only explicitly registered local image identities are reachable. Thumbnail
/// decoding happens away from the main actor, once per asset URL in WebKit.
@MainActor
final class TranscriptAssets: NSObject, WKURLSchemeHandler {
    private enum Asset: Sendable {
        case data(Data)
        case file(URL, maximumPixelSize: Int?)
    }
    private var registered: [String: Asset] = [:]
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func registerAttachment(_ item: ChatAttachment, maximumPixelSize: Int = 160) -> String {
        guard item.kind == .image else { return "" }
        let key = "attachment/" + item.id.uuidString + "-\(maximumPixelSize)"
        registered[key] = .file(AttachmentStore.url(for: item), maximumPixelSize: maximumPixelSize)
        return "seek-local://" + key
    }

    func registerLogo(for message: ChatMessage, dark: Bool) -> String {
        if message.modelIconStyle == .custom, let id = message.customIconID,
           FileManager.default.fileExists(atPath: ModelIconStore.url(for: id).path) {
            let key = "icon/" + id.uuidString
            registered[key] = .file(ModelIconStore.url(for: id), maximumPixelSize: nil)
            return "seek-local://" + key
        }
        let brand = ModelLogo.brandName(model: message.model ?? "", provider: message.modelProvider ?? .openAI,
                                        iconStyle: message.modelIconStyle)
        let key = "model/" + brand + (dark ? "-dark" : "-light")
        if registered[key] == nil {
            let resource = "Model" + brand
            let bitmap: UIImage?
            if let url = Bundle.main.url(forResource: resource, withExtension: "png") { bitmap = UIImage(contentsOfFile: url.path) }
            else { bitmap = UIImage(named: resource) }
            if let image = bitmap ?? UIImage(systemName: "sparkles") {
                // Tint must be baked into PNG pixels. UIImage.withTintColor may
                // carry rendering metadata that pngData does not preserve.
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                format.opaque = false
                let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
                let raster = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
                    image.draw(in: bounds)
                    let tint: UIColor? = brand == "Claude" ? UIColor(red: 0.8, green: 0.47, blue: 0.35, alpha: 1) :
                        (brand == "OpenAI" || bitmap == nil ? (dark ? .white : .black) : nil)
                    if let tint {
                        context.cgContext.setBlendMode(.sourceIn)
                        tint.setFill()
                        context.cgContext.fill(bounds)
                    }
                }
                if let data = raster.pngData() { registered[key] = .data(data) }
            }
        }
        return "seek-local://" + key
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, let host = url.host,
              let asset = registered[host + url.path] else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        tasks[id] = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                switch asset {
                case .data(let data): return data
                case .file(let url, let maximumPixelSize):
                    guard let maximumPixelSize else { return try? Data(contentsOf: url, options: .mappedIfSafe) }
                    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
                            kCGImageSourceCreateThumbnailWithTransform: true
                          ] as CFDictionary) else { return nil as Data? }
                    let output = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
                    CGImageDestinationAddImage(destination, image, nil)
                    guard CGImageDestinationFinalize(destination) else { return nil }
                    return output as Data
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.tasks[id] = nil
            if let data {
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            } else { urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist)) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
    func cancelAll() { for task in tasks.values { task.cancel() }; tasks.removeAll() }
}
