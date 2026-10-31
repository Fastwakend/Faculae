import Foundation
import Observation

struct ExternalFileBatch: Identifiable {
    let id = UUID()
    let urls: [URL]
    var sharedBatch: ShareInbox.Batch?
    var fromFilesFolder = false
}

@MainActor
@Observable
final class ExternalFileImport {
    var pending: ExternalFileBatch?
    private var opening = false

    func checkInbox() {
        try? ShareInbox.prepareImportFolder()
        guard pending == nil, !opening else { return }
        if let inbox = try? ShareInbox.shared(), let batch = try? inbox.pending().first, let urls = try? inbox.urls(batch) {
            pending = ExternalFileBatch(urls: urls, sharedBatch: batch)
        } else if let files = try? FileManager.default.contentsOfDirectory(at: ShareInbox.importFolder,
                       includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
            let urls = files.filter {
                let flags = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return flags?.isRegularFile == true && flags?.isSymbolicLink != true
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            if !urls.isEmpty { pending = ExternalFileBatch(urls: Array(urls.prefix(6)), fromFilesFolder: true) }
        }
    }

    func open(_ url: URL) {
        guard url.isFileURL else { return }
        guard pending == nil, !opening else { failure = "请先处理当前待导入的文件，再打开其他文件。"; return }
        let scoped = url.startAccessingSecurityScopedResource()
        opening = true
        Task {
            defer { opening = false; if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let urls = try await Task.detached(priority: .userInitiated) {
                    let inbox = ShareInbox(root: FileManager.default.temporaryDirectory.appendingPathComponent("OpenIn"))
                    var batch = try inbox.begin()
                    do { try inbox.add(url, to: &batch); return try inbox.urls(batch) }
                    catch { try? inbox.remove(batch); throw error }
                }.value
                pending = ExternalFileBatch(urls: urls)
            } catch { failure = error.localizedDescription }
        }
    }

    var failure: String?

    func finish(_ batch: ExternalFileBatch, consumed: Bool) {
        if consumed, let shared = batch.sharedBatch { try? ShareInbox.shared().remove(shared) }
        if consumed, batch.fromFilesFolder {
            for url in batch.urls where url.deletingLastPathComponent().standardizedFileURL == ShareInbox.importFolder.standardizedFileURL {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if batch.sharedBatch == nil, let parent = batch.urls.first?.deletingLastPathComponent(),
           parent.deletingLastPathComponent().lastPathComponent == "OpenIn" {
            try? FileManager.default.removeItem(at: parent)
        }
        if pending?.id == batch.id { pending = nil }
    }
}
