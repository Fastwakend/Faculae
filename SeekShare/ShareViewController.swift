import UIKit
import SwiftUI
import UniformTypeIdentifiers
import Observation

@objc(SeekShareViewController)
@MainActor
final class ShareViewController: UIViewController {
    private var model: ShareImportModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        guard let extensionContext else { return }
        let model = ShareImportModel(context: extensionContext)
        self.model = model
        let host = UIHostingController(rootView: ShareImportView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
    }
}

@MainActor
@Observable
private final class ShareImportModel {
    let context: NSExtensionContext
    var names: [String] = []
    var loading = true
    var saved = false
    var error: String?
    var usesFilesFolder = false
    var showsExporter = false
    var exportURLs: [URL] = []
    private var inbox: ShareInbox?
    private var batch: ShareInbox.Batch?
    private var progress: Progress?
    private var work: Task<Void, Never>?
    private let cancellation = Progress(totalUnitCount: 1)

    init(context: NSExtensionContext) { self.context = context }

    func load() {
        guard work == nil else { return }
        work = Task {
            defer { loading = false }
            do {
                let inbox: ShareInbox
                var batch: ShareInbox.Batch
                do {
                    let shared = try ShareInbox.shared()
                    batch = try shared.begin(); inbox = shared
                } catch {
                    // A re-signed installation may not have App Group access.
                    // Use Apple's Files picker as the cross-sandbox handoff.
                    usesFilesFolder = true
                    let local = ShareInbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("ShareExport"))
                    batch = try local.begin(); inbox = local
                }
                self.inbox = inbox
                self.batch = batch
                let providers = (context.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
                guard !providers.isEmpty else { throw ShareInbox.Failure.invalid }
                guard providers.count <= 6 else { throw ShareInbox.Failure.limit }
                for provider in providers {
                    try Task.checkCancellation()
                    let payload = try await loadProvider(provider, inbox: inbox, batch: batch)
                    try Task.checkCancellation()
                    batch = payload.batch
                    self.batch = batch; names.append(payload.name)
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func save() {
        guard !loading, error == nil, let inbox, let batch else { return }
        do {
            if usesFilesFolder { exportURLs = try inbox.urls(batch); showsExporter = true }
            else { try inbox.commit(batch); saved = true }
        }
        catch { self.error = error.localizedDescription }
    }

    func close() {
        cancellation.cancel(); work?.cancel(); progress?.cancel()
        if !saved || usesFilesFolder, let inbox, let batch { try? inbox.remove(batch) }
        context.completeRequest(returningItems: nil)
    }

    private struct Payload { let batch: ShareInbox.Batch; let name: String }

    private func loadProvider(_ provider: NSItemProvider, inbox: ShareInbox, batch: ShareInbox.Batch) async throws -> Payload {
        let identifiers = provider.registeredTypeIdentifiers
        let suggestedName = provider.suggestedName
        let type = identifiers.first { id in
            guard let value = UTType(id) else { return false }
            return value.conforms(to: .data) && !value.conforms(to: .url)
        }
        let cancellation = cancellation
        return try await withCheckedThrowingContinuation { continuation in
            let completion = ProviderCompletion<Payload>(continuation)
            // A provider must deliver a local representation. A stalled provider
            // produces an explicit error rather than leaving a permanent spinner.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
                completion.finish { throw NSError(domain: "SeekShare", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件提供方读取超时，请先下载到本机再分享。"] ) }
            }
            if let type {
                progress = provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
                    completion.finish {
                        if let error { throw error }
                        guard let url else { throw ShareInbox.Failure.invalid }
                        let suggested = suggestedName ?? url.lastPathComponent
                        let suffix = UTType(type)?.preferredFilenameExtension
                        let name = (suggested as NSString).pathExtension.isEmpty ? suggested + (suffix.map { "." + $0 } ?? "") : suggested
                        var next = batch
                        try inbox.add(url, name: name, to: &next, isCancelled: { cancellation.isCancelled })
                        return Payload(batch: next, name: name)
                    }
                }
            } else {
                let id = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) ? UTType.fileURL.identifier :
                    (provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) ? UTType.url.identifier : UTType.text.identifier)
                progress = nil
                provider.loadItem(forTypeIdentifier: id, options: nil) { item, error in
                    completion.finish {
                        if let error { throw error }
                        if let url = item as? URL, url.isFileURL {
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            var next = batch
                            try inbox.add(url, to: &next, isCancelled: { cancellation.isCancelled })
                            return Payload(batch: next, name: url.lastPathComponent)
                        }
                        let text = (item as? URL)?.absoluteString ?? (item as? String)
                        guard let text, !text.isEmpty else { throw ShareInbox.Failure.invalid }
                        var next = batch
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        try inbox.add(Data(text.utf8), name: "分享内容.txt", to: &next)
                        return Payload(batch: next, name: "分享内容.txt")
                    }
                }
            }
        }
    }
}

/// Serializes timeout/provider completion, including the synchronous read inside
/// the temporary-file callback. Late callbacks cannot resume or write twice.
private final class ProviderCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    func finish(_ action: () throws -> Value) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let result = Result { try action() }
        lock.unlock()
        continuation.resume(with: result)
    }
}

@MainActor
private struct ShareImportView: View {
    let model: ShareImportModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("导入到 Faculae", systemImage: "square.and.arrow.down")
                        .font(.headline)
                    ForEach(Array(model.names.enumerated()), id: \.offset) { _, name in Label(name, systemImage: "doc") }
                    if model.loading { ProgressView("正在读取分享文件…") }
                    if model.usesFilesFolder {
                        Label("通过系统“文件”导入", systemImage: "folder")
                        Text("请选择“我的 iPhone → Faculae → 导入附件”保存，再返回 Faculae。首次使用请先打开一次 App；也可以存到其他位置后，从 App 的附件菜单选择文件。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = model.error { Text(error).foregroundStyle(.red) }
                    if model.saved {
                        Label("已保存，返回 Faculae 添加到对话。", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                } footer: { Text("最多 6 个文件，单个最多 1 GB。文件不会自动发送给模型。") }
                Section {
                    if model.saved { action("完成", action: model.close) }
                    else { action(model.usesFilesFolder ? "选择文件夹并保存" : "保存到 Faculae", action: model.save).disabled(model.loading || model.error != nil) }
                }
            }
            .navigationTitle("Faculae").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭", action: model.close) } }
        }
        .task { model.load() }
        .sheet(isPresented: Binding(get: { model.showsExporter }, set: { model.showsExporter = $0 })) {
            ShareFileExporter(urls: model.exportURLs) { saved in
                model.showsExporter = false
                model.saved = saved
            }
        }
    }

    @ViewBuilder private func action(_ title: String, action: @escaping () -> Void) -> some View {
        if #available(iOS 26, *) { Button(title, action: action).buttonStyle(.glass).frame(maxWidth: .infinity) }
        else { Button(title, action: action).buttonStyle(.bordered).frame(maxWidth: .infinity) }
    }
}

private struct ShareFileExporter: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish(false) }
    }
}
