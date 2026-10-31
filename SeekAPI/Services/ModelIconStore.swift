import Foundation
import UIKit
import ImageIO
import SeekCore

/// Shared local icon files keep small UUID references in models and replies.
actor ModelIconStore {
    static let shared = ModelIconStore()
    private var importedThisSession = Set<UUID>()
    private static let maximumInputBytes = 20 * 1024 * 1024

    nonisolated private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeekAPI/ModelIcons", isDirectory: true)
    }

    nonisolated static func url(for id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("png")
    }

    @MainActor private static let cache: NSCache<NSUUID, UIImage> = {
        let cache = NSCache<NSUUID, UIImage>()
        cache.countLimit = 64
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    @MainActor static func image(for id: UUID) -> UIImage? {
        if let cached = cache.object(forKey: id as NSUUID) { return cached }
        guard let image = UIImage(contentsOfFile: url(for: id).path) else { return nil }
        cache.setObject(image, forKey: id as NSUUID, cost: 256 * 256 * 4)
        return image
    }

    func importImage(_ data: Data) throws -> UUID {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= Self.maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary),
              let png = UIImage(cgImage: thumbnail).pngData(), png.count <= 512 * 1024 else {
            throw APIError.provider("图片无法读取，请选择 20 MB 以内的 PNG、JPEG、HEIC 等图片。")
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        var location = Self.folder
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try location.setResourceValues(flags)
        let id = UUID()
        try png.write(to: Self.url(for: id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        importedThisSession.insert(id)
        return id
    }

    func importFile(_ url: URL) throws -> UUID {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= Self.maximumInputBytes else {
            throw APIError.provider("请选择 20 MB 以内的图片文件。")
        }
        return try importImage(Data(contentsOf: url, options: .mappedIfSafe))
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.url(for: id))
        importedThisSession.remove(id)
    }

    func prune(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil) else { return }
        // A delayed launch cleanup must not remove an icon just imported by an editor.
        let retained = ids.union(importedThisSession)
        for file in files where file.pathExtension == "png" {
            if let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), !retained.contains(id) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
