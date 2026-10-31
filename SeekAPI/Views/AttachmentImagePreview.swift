import SwiftUI
import SeekCore

/// Preview the saved attachment, never a WebKit thumbnail or an arbitrary URL.
@MainActor
struct AttachmentImagePreview: View {
    let attachment: ChatAttachment
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loading = true
    @State private var saving = false
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image { ZoomableAttachmentImage(image: image).ignoresSafeArea(edges: .bottom) }
                else if loading { ProgressView().tint(.white) }
                else { ContentUnavailableView("图片无法读取", systemImage: "photo.badge.exclamationmark", description: Text("照片可能已从本机移除。")) }
            }
            .navigationTitle(attachment.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }.foregroundStyle(.white).tint(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await savePhoto() } } label: {
                        if saving { ProgressView().tint(.white) }
                        else { Label("保存到相册", systemImage: "square.and.arrow.down").foregroundStyle(.white) }
                    }
                    .tint(.white)
                    .disabled(image == nil || saving).accessibilityIdentifier("attachment.saveImage")
                }
            }
            .background { PhotoPreviewNotice(message: $notice).frame(width: 0, height: 0) }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .task(id: attachment.id) {
            loading = true
            let url = AttachmentStore.url(for: attachment)
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url, options: .mappedIfSafe) }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
            loading = false
        }
    }

    private func savePhoto() async {
        guard !saving, image != nil else { return }
        saving = true
        defer { saving = false }
        do {
            let converted = try await PhotoLibrarySaver.save(url: AttachmentStore.url(for: attachment), filename: attachment.name)
            notice = converted ? "已转换为 PNG 并保存到系统相册，原始图片保留在 App 中。" : "已保存到系统相册。"
        } catch { notice = "保存失败：" + error.localizedDescription }
    }
}

/// A native alert with an explicit local tint, including the acknowledgement
/// action. Do not change the application's global alert appearance.
@MainActor
private struct PhotoPreviewNotice: UIViewControllerRepresentable {
    @Binding var message: String?
    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ controller: Host, context: Context) {
        controller.message = message
        controller.onDismiss = { message = nil }
        controller.showIfNeeded()
    }
    final class Host: UIViewController {
        var message: String?
        var onDismiss: (() -> Void)?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); showIfNeeded() }
        func showIfNeeded() {
            guard let message, viewIfLoaded?.window != nil, presentedViewController == nil else { return }
            let alert = UIAlertController(title: "图片", message: message, preferredStyle: .alert)
            alert.overrideUserInterfaceStyle = .dark
            alert.view.tintColor = .white
            alert.addAction(UIAlertAction(title: "知道了", style: .default) { [weak self] _ in self?.onDismiss?() })
            present(alert, animated: true)
        }
    }
}

@MainActor
private struct ZoomableAttachmentImage: UIViewRepresentable {
    let image: UIImage
    func makeUIView(context: Context) -> ImageZoomView { ImageZoomView(image: image) }
    func updateUIView(_ view: ImageZoomView, context: Context) {}

    final class ImageZoomView: UIScrollView, UIScrollViewDelegate {
        private let picture: UIImageView
        private var previousSize: CGSize = .zero
        init(image: UIImage) {
            picture = UIImageView(image: image)
            super.init(frame: .zero)
            backgroundColor = .black
            picture.contentMode = .scaleAspectFit
            picture.accessibilityLabel = "对话中的图片，可双指缩放"
            picture.isAccessibilityElement = true
            addSubview(picture)
            delegate = self
            minimumZoomScale = 1; maximumZoomScale = 6
            showsVerticalScrollIndicator = false; showsHorizontalScrollIndicator = false
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
        override func layoutSubviews() {
            super.layoutSubviews()
            if previousSize != bounds.size {
                previousSize = bounds.size
                setZoomScale(1, animated: false)
                picture.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }
        @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
            if zoomScale > 1 { setZoomScale(1, animated: true) }
            else {
                let point = gesture.location(in: picture)
                zoom(to: CGRect(x: point.x - bounds.width / 6, y: point.y - bounds.height / 6,
                                width: bounds.width / 3, height: bounds.height / 3), animated: true)
            }
        }
    }
}
