import SwiftUI
import SeekCore

@MainActor
struct ExternalFileImportView: View {
    let batch: ExternalFileBatch
    let store: AppStore
    let onClose: () -> Void
    @State private var importing = false
    @State private var error: String?
    @State private var finished = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(batch.urls, id: \.self) { url in
                        Label(url.lastPathComponent, systemImage: "doc.badge.arrow.up")
                            .lineLimit(2)
                    }
                } header: { Text("来自系统分享的文件") } footer: {
                    Text("添加到当前对话的附件草稿，发送前可检查或移除。支持图片、PDF、办公文档及文本；每条消息最多 6 个附件，单个最多 1 GB。")
                }
                if importing { ProgressView("正在读取文件…") }
                if let error { Text(error).foregroundStyle(.red).font(.footnote) }
                Section {
                    Button(action: importFiles) {
                        Label("添加到对话", systemImage: "plus.message")
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .seekNativeGlassButton().disabled(importing)
                }
            }
            .navigationTitle("导入附件").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("取消") { close(consumed: false) }.disabled(importing)
                }
            }
        }
        .seekSheetContentBackground()
        .interactiveDismissDisabled(importing)
        .onDisappear {
            if !finished { store.externalFiles.finish(batch, consumed: false) }
        }
    }

    private func close(consumed: Bool) {
        finished = true
        store.externalFiles.finish(batch, consumed: consumed)
        onClose()
    }

    private func importFiles() {
        guard !importing else { return }
        guard store.draftAttachments.count + batch.urls.count <= 6 else {
            error = "当前草稿与分享文件合计超过 6 个，请先移除部分附件。"; return
        }
        importing = true; error = nil
        Task {
            defer { importing = false }
            var items: [ChatAttachment] = []
            do {
                for url in batch.urls { items.append(try await AttachmentStore.shared.importFile(url)) }
                guard store.draftAttachments.count + items.count <= 6,
                      (store.draftAttachments + items).reduce(0, { $0 + $1.byteCount }) <= ShareInbox.totalLimit else {
                    throw ShareInbox.Failure.limit
                }
                store.draftAttachments.append(contentsOf: items)
                close(consumed: true)
            } catch {
                await AttachmentStore.shared.remove(items)
                self.error = error.localizedDescription
            }
        }
    }
}
