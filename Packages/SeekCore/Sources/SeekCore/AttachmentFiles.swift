import Foundation

public enum AttachmentLimits {
    public static let fileBytes = 1024 * 1024 * 1024
    public static let count = 6
    public static let batchBytes = count * fileBytes
}

/// Bounded file IO shared by the app, Share extension, and Linux regressions.
public enum AttachmentFileIO {
    public static let chunkBytes = 192 * 1024

    public static func size(_ url: URL, limit: Int = AttachmentLimits.fileBytes) throws -> Int {
        guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        // Use the materialized file's filesystem attributes. Provider URL
        // resource metadata may omit regular-file/size keys after a picker copy.
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values[.type] as? FileAttributeType == .typeRegular,
              let bytes = (values[.size] as? NSNumber)?.intValue, bytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard bytes <= limit else { throw CocoaError(.fileReadTooLarge) }
        return bytes
    }

    @discardableResult
    public static func copy(_ source: URL, to destination: URL, limit: Int = AttachmentLimits.fileBytes,
                            validateText: Bool = false, isCancelled: @Sendable () -> Bool = { false }) throws -> Int {
        _ = try size(source, limit: limit)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: temporary)
        defer { try? writer.close() }
        var bytes = 0
        var utf8 = AttachmentUTF8Validator()
        while let data = try reader.read(upToCount: chunkBytes), !data.isEmpty {
            try Task.checkCancellation()
            if isCancelled() { throw CancellationError() }
            bytes += data.count
            guard bytes <= limit else { throw CocoaError(.fileReadTooLarge) }
            if validateText { try utf8.append(data) }
            try writer.write(contentsOf: data)
        }
        guard bytes > 0 else { throw CocoaError(.fileReadCorruptFile) }
        if validateText { try utf8.finish() }
        try writer.close()
        try FileManager.default.moveItem(at: temporary, to: destination)
        return bytes
    }
}

/// Incremental validation retains only the UTF-8 sequence state, including when
/// an emoji or CJK scalar straddles a file chunk. Binary/control bytes are rejected.
struct AttachmentUTF8Validator {
    private var remaining = 0
    private var lower: UInt8 = 0x80
    private var upper: UInt8 = 0xBF
    mutating func append(_ data: Data) throws {
        for byte in data {
            if remaining > 0 {
                guard byte >= lower, byte <= upper else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                remaining -= 1; lower = 0x80; upper = 0xBF
            } else {
                switch byte {
                case 9, 10, 13, 0x20...0x7F: break
                case 0xC2...0xDF: remaining = 1
                case 0xE0: remaining = 2; lower = 0xA0
                case 0xE1...0xEC, 0xEE...0xEF: remaining = 2
                case 0xED: remaining = 2; upper = 0x9F
                case 0xF0: remaining = 3; lower = 0x90
                case 0xF1...0xF3: remaining = 3
                case 0xF4: remaining = 3; upper = 0x8F
                default: throw CocoaError(.fileReadInapplicableStringEncoding)
                }
            }
        }
    }
    func finish() throws {
        guard remaining == 0 else { throw CocoaError(.fileReadInapplicableStringEncoding) }
    }
}
