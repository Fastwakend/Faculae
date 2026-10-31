import Foundation
#if canImport(SeekCore)
import SeekCore
#endif

/// Shared by the containing app and its Share extension. Only committed batches
/// are visible to the app; a provider's temporary URL never escapes its callback.
struct ShareInbox {
    static let groupID = "group.app.seekapi.ios"
    static let fileLimit = AttachmentLimits.fileBytes
    static let totalLimit = AttachmentLimits.batchBytes
    let root: URL

    struct Batch: Codable, Identifiable, Equatable {
        let id: UUID
        let createdAt: Date
        var files: [String]
    }

    enum Failure: LocalizedError {
        case unavailable, invalid, limit
        var errorDescription: String? {
            switch self {
            case .unavailable: return "共享空间不可用。请确认主 App 和分享扩展使用相同 App Group 权限签名；也可在“文件”中使用“用 Faculae 打开”。"
            case .invalid: return "文件不存在、为空或无法读取，请下载到本机后重试。"
            case .limit: return "每次最多分享 6 个文件，单个最多 1 GB，合计最多 6 GB。"
            }
        }
    }

    #if os(iOS)
    static func shared() throws -> ShareInbox {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else { throw Failure.unavailable }
        return ShareInbox(root: url.appendingPathComponent("ShareInbox", isDirectory: true))
    }

    static var importFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("导入附件", isDirectory: true)
    }

    static func prepareImportFolder() throws {
        try FileManager.default.createDirectory(at: importFolder, withIntermediateDirectories: true)
    }
    #endif

    func begin() throws -> Batch {
        let batch = Batch(id: UUID(), createdAt: Date(), files: [])
        try FileManager.default.createDirectory(at: folder(batch), withIntermediateDirectories: true)
        return batch
    }

    func folder(_ batch: Batch) -> URL { root.appendingPathComponent(batch.id.uuidString, isDirectory: true) }

    func add(_ source: URL, name: String? = nil, to batch: inout Batch,
             isCancelled: @Sendable () -> Bool = { false }) throws {
        guard batch.files.count < 6 else { throw Failure.limit }
        let total = try urls(batch).reduce(0) { $0 + (try AttachmentFileIO.size($1)) }
        let bytes = try AttachmentFileIO.size(source)
        guard bytes + total <= Self.totalLimit else { throw Failure.limit }
        let name = filename(name ?? source.lastPathComponent, in: batch)
        let target = folder(batch).appendingPathComponent(name)
        try AttachmentFileIO.copy(source, to: target, limit: min(Self.fileLimit, Self.totalLimit - total), isCancelled: isCancelled)
        batch.files.append(name)
    }

    func add(_ data: Data, name: String, to batch: inout Batch) throws {
        guard !data.isEmpty else { throw Failure.invalid }
        guard batch.files.count < 6, data.count <= Self.fileLimit else { throw Failure.limit }
        let total = try urls(batch).reduce(0) { sum, url in
            sum + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        guard total + data.count <= Self.totalLimit else { throw Failure.limit }
        let filename = filename(name, in: batch)
        try data.write(to: folder(batch).appendingPathComponent(filename), options: .atomic)
        batch.files.append(filename)
    }

    private func filename(_ name: String, in batch: Batch) -> String {
        // Do not trust provider filenames as paths; preserve only a bounded suffix.
        let base = String(URL(fileURLWithPath: name).lastPathComponent.suffix(140))
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "\\", with: "_")
        return "\(batch.files.count + 1)-" + (base.isEmpty ? "文件" : base)
    }

    func commit(_ batch: Batch) throws {
        guard !batch.files.isEmpty else { throw Failure.invalid }
        _ = try urls(batch)
        try JSONEncoder().encode(batch).write(to: folder(batch).appendingPathComponent("manifest.json"), options: .atomic)
    }

    func pending() throws -> [Batch] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")), data.count <= 16384,
                  let batch = try? JSONDecoder().decode(Batch.self, from: data), batch.id == id,
                  (try? urls(batch)) != nil else { return nil }
            return batch
        }.sorted { $0.createdAt < $1.createdAt }
    }

    func urls(_ batch: Batch) throws -> [URL] {
        guard batch.files.count <= 6 else { throw Failure.limit }
        var total = 0
        return try batch.files.map { name in
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  name != "manifest.json" else { throw Failure.invalid }
            let url = folder(batch).appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let bytes = values.fileSize, bytes > 0 else { throw Failure.invalid }
            total += bytes
            guard bytes <= Self.fileLimit, total <= Self.totalLimit else { throw Failure.limit }
            return url
        }
    }

    func remove(_ batch: Batch) throws { try FileManager.default.removeItem(at: folder(batch)) }
}
