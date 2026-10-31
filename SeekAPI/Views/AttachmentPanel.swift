import SwiftUI
import PhotosUI
import Photos
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import SeekCore

@MainActor
struct AttachmentPanel: View {
    @Binding var attachments: [ChatAttachment]
    @Environment(\.dismiss) private var dismiss
    @State private var photos: [PhotosPickerItem] = []
    @State private var assets: [PHAsset] = []
    @State private var assetSelections: [String: UUID] = [:]
    @State private var showsCamera = false
    @State private var showsFiles = false
    @State private var importNotice: String?
    @State private var loading = false
    @State private var photoHint = "显示最近照片"
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            SeekGlassGroup {
                VStack(spacing: 20) {
                    HStack {
                        Text("添加附件").font(.headline)
                        Spacer()
                        if loading { ProgressView().accessibilityLabel("正在导入") }
                        Button("完成") { dismiss() }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .seekGlass(in: Capsule(), interactive: true)
                            .disabled(loading)
                    }
                    if assets.isEmpty {
                        Button(action: requestRecentPhotos) {
                            VStack(spacing: 10) {
                                Image(systemName: "photo.on.rectangle.angled").font(.title2)
                                Text(photoHint).font(.subheadline)
                                Text("也可直接使用下方相册选择照片").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 105)
                        }
                        .disabled(loading)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 10) {
                                ForEach(assets, id: \.localIdentifier) { asset in
                                    Button { toggleAsset(asset) } label: {
                                        RecentPhoto(asset: asset, selected: isSelected(asset))
                                            .frame(width: 94, height: 104)
                                            .contentShape(RoundedRectangle(cornerRadius: 18))
                                    }
                                    .frame(width: 94, height: 104)
                                    .contentShape(RoundedRectangle(cornerRadius: 18))
                                    .disabled(loading)
                                    .accessibilityLabel("最近照片")
                                    .accessibilityAddTraits(isSelected(asset) ? .isSelected : [])
                                }
                            }
                        }
                        .frame(height: 104)
                    }
                    HStack(spacing: 12) {
                        Button(action: openCamera) { AttachmentTile(symbol: "camera", title: "拍照") }
                        PhotosPicker(selection: $photos, maxSelectionCount: max(1, 6 - attachments.count), matching: .images) {
                            AttachmentTile(symbol: "photo", title: "相册")
                        }
                        Button { importNotice = nil; showsFiles = true } label: { AttachmentTile(symbol: "paperclip", title: "文件") }
                    }
                    .disabled(loading || attachments.count >= 6)
                    Text("已选 \(attachments.count)/6 · 单文件最多 1 GB · 图片、PDF、办公文档及文本/代码")
                        .font(.caption).foregroundStyle(.secondary)
                    if let importNotice {
                        Text(importNotice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            .accessibilityIdentifier("attachments.importResult")
                    }
                }
                .padding(20)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Color(uiColor: .label)).tint(Color(uiColor: .label))
        .buttonStyle(.plain)
        .seekSheetContentBackground()
        .presentationDetents([.height(350), .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(loading)
        .onAppear(perform: loadAuthorizedPhotos)
        .onChange(of: photos) { _, items in importPhotos(items) }
        .alert("附件提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
        .fullScreenCover(isPresented: $showsCamera) {
            CameraCapture { data in
                showsCamera = false
                guard let data else { return }
                loading = true
                Task {
                    defer { loading = false }
                    do { try await append(AttachmentStore.shared.importImage(data)) }
                    catch { errorText = error.localizedDescription }
                }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showsFiles) {
            AttachmentFilePicker { urls in
                showsFiles = false
                importSelectedFiles(urls)
            }
        }
    }

    private func importSelectedFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        loading = true
        Task {
            defer { loading = false }
            var added: [String] = []
            var failures: [String] = []
            for url in urls {
                do {
                    let item = try await AttachmentStore.shared.importFile(url)
                    try await append(item)
                    added.append(item.name)
                } catch {
                    failures.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                }
            }
            if !added.isEmpty { importNotice = "已添加 \(added.count) 个文件：" + added.joined(separator: "、") }
            if !failures.isEmpty { errorText = failures.joined(separator: "\n") }
            // Keep the panel mounted until the picker dismissal has completed.
            // The count/notice and draft strip update immediately; Done closes it.
        }
    }

    private func openCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            errorText = "这台设备暂时无法使用相机。"; return
        }
        Task {
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            if allowed { showsCamera = true }
            else { errorText = "相机权限未开启，请在系统设置中允许 Faculae 使用相机。" }
        }
    }

    private func append(_ item: ChatAttachment) async throws {
        guard attachments.count < 6 else {
            await AttachmentStore.shared.remove([item])
            throw APIError.provider("每条消息最多添加 6 个附件。")
        }
        guard attachments.reduce(0, { $0 + $1.byteCount }) + item.byteCount <= AttachmentLimits.batchBytes else {
            await AttachmentStore.shared.remove([item])
            throw APIError.provider("附件总大小不能超过 6 GB。")
        }
        attachments.append(item)
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loading = true
        Task {
            defer { loading = false; photos = [] }
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw APIError.provider("照片下载失败，请重试。") }
                    try await append(AttachmentStore.shared.importImage(data))
                } catch { errorText = error.localizedDescription }
            }
        }
    }

    private func requestRecentPhotos() {
        Task {
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            if status == .authorized || status == .limited { loadAuthorizedPhotos() }
            else { photoHint = "未获得照片权限，请使用下方相册" }
        }
    }

    private func loadAuthorizedPhotos() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 16
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var values: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in values.append(asset) }
        assets = values
        if values.isEmpty { photoHint = "暂无可访问的照片，请使用下方相册" }
    }

    private func isSelected(_ asset: PHAsset) -> Bool {
        guard let id = assetSelections[asset.localIdentifier] else { return false }
        return attachments.contains { $0.id == id }
    }

    private func toggleAsset(_ asset: PHAsset) {
        Haptics.shared.play(.listItem)
        if let id = assetSelections[asset.localIdentifier], let item = attachments.first(where: { $0.id == id }) {
            attachments.removeAll { $0.id == id }
            Task { await AttachmentStore.shared.remove([item]) }
            return
        }
        guard attachments.count < 6 else { errorText = "每条消息最多添加 6 个附件。"; return }
        loading = true
        Task {
            defer { loading = false }
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
                    PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                        if let data { continuation.resume(returning: data) }
                        else { continuation.resume(throwing: (info?[PHImageErrorKey] as? Error) ?? APIError.provider("照片读取失败。")) }
                    }
                }
                let attachment = try await AttachmentStore.shared.importImage(data)
                try await append(attachment)
                assetSelections[asset.localIdentifier] = attachment.id
            } catch { errorText = error.localizedDescription }
        }
    }
}

@MainActor
private struct AttachmentTile: View {
    let symbol: String
    let title: String
    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 25))
            Text(title).font(.body.weight(.medium))
        }
        .frame(maxWidth: .infinity, minHeight: 95)
        .seekGlass(in: RoundedRectangle(cornerRadius: 22), interactive: true)
    }
}

@MainActor
private struct RecentPhoto: View {
    let asset: PHAsset
    let selected: Bool
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var representedID: String?
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Color(uiColor: .tertiarySystemFill).overlay { Image(systemName: "photo") } }
            }
            .frame(width: 94, height: 104).clipped()
            .contentShape(Rectangle())
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.title3).symbolRenderingMode(.palette)
                .foregroundStyle(selected ? SeekTheme.blue : Color.white, Color.black.opacity(0.25))
                .padding(6)
        }
        .frame(width: 94, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onAppear {
            let identifier = asset.localIdentifier
            representedID = identifier
            let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
            requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 220, height: 240), contentMode: .aspectFill, options: options) { image, info in
                guard info?[PHImageCancelledKey] as? Bool != true else { return }
                Task { @MainActor in
                    guard representedID == identifier else { return }
                    self.image = image
                }
            }
        }
        .onDisappear {
            representedID = nil
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil
        }
    }
}

@MainActor
private struct CameraCapture: UIViewControllerRepresentable {
    let onFinish: (Data?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController(); picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onFinish: (Data?) -> Void
        init(onFinish: @escaping (Data?) -> Void) { self.onFinish = onFinish }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { onFinish(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.9))
        }
    }
}

@MainActor
struct AttachmentStrip: View {
    let attachments: [ChatAttachment]
    var onRemove: ((ChatAttachment) -> Void)? = nil
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 8) {
                        if attachment.kind == .image, let image = AttachmentThumbnails.image(for: attachment) {
                            Image(uiImage: image).resizable().scaledToFill().frame(width: 42, height: 42)
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        } else {
                            Image(systemName: attachment.kind == .pdf ? "doc.richtext" : "doc.text")
                                .font(.title3).frame(width: 32)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(attachment.name).lineLimit(1).frame(maxWidth: 130, alignment: .leading)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        if let onRemove {
                            Button { onRemove(attachment) } label: { Image(systemName: "xmark.circle.fill").frame(width: 32, height: 42) }
                                .accessibilityLabel("移除\(attachment.name)")
                        }
                    }
                    .padding(8).background(SeekTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(Color(uiColor: .label))
    }
}

@MainActor
private enum AttachmentThumbnails {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.countLimit = 48
        return cache
    }()

    static func image(for attachment: ChatAttachment) -> UIImage? {
        let key = attachment.id.uuidString as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(AttachmentStore.url(for: attachment) as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 160,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let image = UIImage(cgImage: thumbnail)
        cache.setObject(image, forKey: key)
        return image
    }
}
