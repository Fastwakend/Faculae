import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import SeekCore

@MainActor
struct ModelIconSettings: View {
    @Binding var model: APIModel
    let provider: APIProvider
    @Binding var importing: Bool
    @State private var photo: PhotosPickerItem?
    @State private var showsFiles = false
    @State private var errorText: String?
    @State private var importTask: Task<Void, Never>?

    private var selection: Binding<ModelIconStyle> {
        Binding(get: {
            if model.iconStyle == .custom && model.customIconID == nil { return .automatic }
            return model.iconStyle ?? .automatic
        }, set: { model.iconStyle = $0 == .automatic ? nil : $0 })
    }

    var body: some View {
        Section {
            HStack(spacing: 14) {
                ModelLogo(model: model, provider: provider, size: 44)
                VStack(alignment: .leading, spacing: 5) {
                    Text("图标预览").font(.subheadline)
                    Text(selection.wrappedValue.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if importing { ProgressView().accessibilityLabel("正在导入图标") }
            }
            .padding(.vertical, 8)
            Picker("图标来源", selection: selection) {
                ForEach(ModelIconStyle.allCases.filter { $0 != .custom || model.customIconID != nil }) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("settings.model.icon")
            PhotosPicker(selection: $photo, matching: .images) {
                Label("从相册选择图片", systemImage: "photo")
            }
            .accessibilityIdentifier("settings.model.icon.photos")
            Button { showsFiles = true } label: {
                Label("从文件导入图片", systemImage: "folder")
            }
            .accessibilityIdentifier("settings.model.icon.file")
            if model.customIconID != nil {
                Button(role: .destructive) {
                    if model.iconStyle == .custom { model.iconStyle = nil }
                    model.customIconID = nil
                } label: { Label("移除自定义图片", systemImage: "trash") }
            }
        } header: { Text("模型图标") } footer: {
            Text("可使用四家供应商 Logo，或导入自己的图片。返回供应商页面保存后生效。")
        }
        .disabled(importing)
        .onChange(of: photo) { _, item in
            guard let item else { return }
            startImport {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw APIError.provider("照片下载失败，请重试。")
                }
                return try await ModelIconStore.shared.importImage(data)
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                startImport { try await ModelIconStore.shared.importFile(url) }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { errorText = error.localizedDescription }
            }
        }
        .onDisappear { importTask?.cancel() }
        .alert("图标提示", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("知道了", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }

    private func startImport(_ operation: @escaping @Sendable () async throws -> UUID) {
        importTask?.cancel()
        importing = true
        errorText = nil
        importTask = Task {
            defer { importing = false; photo = nil }
            do {
                let id = try await operation()
                guard !Task.isCancelled else {
                    await ModelIconStore.shared.remove(id)
                    return
                }
                model.customIconID = id
                model.iconStyle = .custom
            } catch {
                if !Task.isCancelled { errorText = error.localizedDescription }
            }
        }
    }
}
