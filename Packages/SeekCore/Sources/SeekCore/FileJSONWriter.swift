import Foundation

struct JSONFileString {
    enum Encoding { case text, base64 }
    let url: URL
    let encoding: Encoding
    var prefix = ""
}

/// Writes provider JSON to disk without constructing a 1GB Data or base64 String.
/// File references are typed values, never text placeholders that a user can forge.
enum FileJSONWriter {
    static func write(_ value: Any, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let writer = try FileHandle(forWritingTo: url)
        var committed = false
        defer {
            try? writer.close()
            if !committed { try? FileManager.default.removeItem(at: url) }
        }
        func raw(_ value: String) throws { try writer.write(contentsOf: Data(value.utf8)) }
        func escaped(_ data: Data) throws {
            var output = Data(); output.reserveCapacity(data.count + 32)
            for byte in data {
                switch byte {
                case 0x22: output.append(contentsOf: [0x5C, 0x22])
                case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
                case 0..<0x20: output.append(contentsOf: String(format: "\\u%04x", byte).utf8)
                default: output.append(byte)
                }
            }
            try writer.write(contentsOf: output)
        }
        func file(_ file: JSONFileString) throws {
            _ = try AttachmentFileIO.size(file.url)
            let reader = try FileHandle(forReadingFrom: file.url)
            defer { try? reader.close() }
            try raw("\""); try escaped(Data(file.prefix.utf8))
            var bytes = 0, carry = Data(), utf8 = AttachmentUTF8Validator()
            while let chunk = try reader.read(upToCount: AttachmentFileIO.chunkBytes), !chunk.isEmpty {
                try Task.checkCancellation()
                bytes += chunk.count
                guard bytes <= AttachmentLimits.fileBytes else { throw CocoaError(.fileReadTooLarge) }
                switch file.encoding {
                case .text: try utf8.append(chunk); try escaped(chunk)
                case .base64:
                    carry.append(chunk)
                    let complete = carry.count / 3 * 3
                    if complete > 0 {
                        try writer.write(contentsOf: carry.prefix(complete).base64EncodedData())
                        carry = Data(carry.dropFirst(complete))
                    }
                }
            }
            if file.encoding == .text { try utf8.finish() }
            if !carry.isEmpty { try writer.write(contentsOf: carry.base64EncodedData()) }
            try raw("\"")
        }
        func encode(_ value: Any) throws {
            try Task.checkCancellation()
            if let reference = value as? JSONFileString { try file(reference) }
            else if let object = value as? [String: Any] {
                try raw("{")
                for (index, key) in object.keys.sorted().enumerated() {
                    if index > 0 { try raw(",") }
                    try encode(key); try raw(":"); try encode(object[key]!)
                }
                try raw("}")
            } else if let array = value as? [Any] {
                try raw("[")
                for (index, item) in array.enumerated() { if index > 0 { try raw(",") }; try encode(item) }
                try raw("]")
            } else { try writer.write(contentsOf: JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])) }
        }
        try encode(value)
        try writer.close(); committed = true
    }
}
