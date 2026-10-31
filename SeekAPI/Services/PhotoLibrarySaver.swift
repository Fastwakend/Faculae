import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import SeekCore

/// App attachment URLs are extensionless UUIDs. Import image bytes, rather than
/// asking Photos to infer the resource from that storage URL or MIME metadata.
enum PhotoLibrarySaver {
    private struct Resource: Sendable {
        let data: Data
        let typeIdentifier: String
        let filename: String
        let convertedToPNG: Bool
    }

    /// Returns true when a PNG copy was needed. The original attachment is kept.
    static func save(url: URL, filename: String) async throws -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let authorization = status == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : status
        guard authorization == .authorized || authorization == .limited else {
            throw APIError.provider("请在系统设置中允许 Faculae 添加照片，再尝试保存。")
        }
        let resource = try await Task.detached(priority: .userInitiated) {
            try prepare(url: url, filename: filename)
        }.value
        try Task.checkCancellation()
        do {
            try await commit(resource)
            return resource.convertedToPNG
        } catch {
            let photosError = error as NSError
            guard photosError.domain == PHPhotosErrorDomain,
                  photosError.code == PHPhotosError.Code.invalidResource.rawValue else { throw error }
            // Retry only an explicitly rejected resource, never a timeout or an
            // ambiguous transaction. Decode/re-encode strips incompatible data.
            let canonical = try await Task.detached(priority: .userInitiated) {
                try prepare(url: url, filename: filename, forcePNG: true)
            }.value
            try Task.checkCancellation()
            try await commit(canonical)
            return true
        }
    }

    private static func commit(_ resource: Resource) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = resource.filename
            options.uniformTypeIdentifier = resource.typeIdentifier
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(with: .photo, data: resource.data, options: options)
        }
    }

    private static func prepare(url: URL, filename: String, forcePNG: Bool = false) throws -> Resource {
        _ = try AttachmentFileIO.size(url, limit: 134_217_728)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let identifier = CGImageSourceGetType(source),
              let type = UTType(identifier as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 40_000_000 else {
            throw APIError.provider("图片文件不完整或无法解码，请重新生成或添加图片。")
        }
        let supported = [UTType.jpeg, .png, .heic, .heif].contains(type)
        if supported && !forcePNG {
            return Resource(data: data, typeIdentifier: type.identifier,
                filename: photoFilename(filename, extension: type.preferredFilenameExtension ?? "jpg"), convertedToPNG: false)
        }
        // Transform orientation at full resolution and preserve alpha. Avoid
        // carrying arbitrary source metadata into the compatible PNG resource.
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary) else { throw APIError.provider("图片无法解码，未能保存到相册。") }
        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil) else {
            throw APIError.malformedResponse
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw APIError.provider("图片转换失败，请重试。") }
        return Resource(data: png as Data, typeIdentifier: UTType.png.identifier,
            filename: photoFilename(filename, extension: "png"), convertedToPNG: true)
    }

    private static func photoFilename(_ filename: String, extension suffix: String) -> String {
        let stem = ((filename as NSString).lastPathComponent as NSString).deletingPathExtension
            .components(separatedBy: .controlCharacters).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (stem.isEmpty ? "Faculae" : String(stem.prefix(100))) + "." + suffix
    }
}
