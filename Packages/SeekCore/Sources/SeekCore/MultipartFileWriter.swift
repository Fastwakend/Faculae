import Foundation

/// Stream reference images to disk; never construct a multipart body in memory.
enum MultipartFileWriter {
    static func write(fields: [String: Any], images: [ChatAttachment], files: [UUID: URL],
                      boundary: String, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: destination)
        var committed = false
        defer { try? writer.close(); if !committed { try? FileManager.default.removeItem(at: destination) } }
        func raw(_ text: String) throws { try writer.write(contentsOf: Data(text.utf8)) }
        for key in fields.keys.sorted() {
            try Task.checkCancellation()
            try raw("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
        }
        for image in images {
            guard let file = files[image.id] else { throw APIError.provider("参考图读取失败，请重新添加。") }
            _ = try AttachmentFileIO.size(file)
            let suffix = image.mimeType == "image/png" ? "png" : (image.mimeType == "image/webp" ? "webp" : "jpg")
            try raw("--\(boundary)\r\nContent-Disposition: form-data; name=\"image[]\"; filename=\"\(image.id.uuidString).\(suffix)\"\r\nContent-Type: \(image.mimeType)\r\n\r\n")
            let reader = try FileHandle(forReadingFrom: file)
            defer { try? reader.close() }
            var count = 0
            while let chunk = try reader.read(upToCount: AttachmentFileIO.chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation()
                count += chunk.count
                guard count <= AttachmentLimits.fileBytes else { throw CocoaError(.fileReadTooLarge) }
                try writer.write(contentsOf: chunk)
            }
            guard count > 0 else { throw CocoaError(.fileReadCorruptFile) }
            try raw("\r\n")
        }
        try raw("--\(boundary)--\r\n")
        try writer.close(); committed = true
    }
}
