import Foundation
import CoreFoundation
import CZlib
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Local text extraction: no macros, external relationships, or embedded files run.
public enum DocumentText {
    public static let officeExtensions: Set<String> = ["docx", "xlsx", "pptx", "odt", "ods", "odp"]
    public static func extract(_ data: Data, filename: String) throws -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        if officeExtensions.contains(ext) { return try office(data, ext: ext) }
        guard !["doc", "xls", "ppt", "pages", "numbers", "key", "zip", "rar", "7z", "exe"].contains(ext) else {
            throw APIError.provider("该格式暂不能提取文字，请转换为 DOCX、XLSX、PPTX、PDF 或文本后上传。")
        }
        guard data.count <= 1024 * 1024 else { throw APIError.provider("文本文件最多 1 MB。") }
        let text = try decode(data)
        if ["html", "htm"].contains(ext) { return try checked(htmlText(text)) }
        return try checked(text)
    }

    public static func decode(_ data: Data) throws -> String {
        let result: String?
        if data.starts(with: [0xFF, 0xFE]) { result = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) }
        else if data.starts(with: [0xFE, 0xFF]) { result = String(data: data.dropFirst(2), encoding: .utf16BigEndian) }
        else if data.starts(with: [0xEF, 0xBB, 0xBF]) { result = String(data: data.dropFirst(3), encoding: .utf8) }
        else if let utf8 = String(data: data, encoding: .utf8) { result = utf8 }
        else {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(0x0632))) // GB18030
            result = String(data: data, encoding: encoding)
        }
        guard let result, !result.contains("\0"), !result.unicodeScalars.contains(where: { $0.value < 32 && ![9,10,13].contains($0.value) }) else {
            throw APIError.provider("文件不是可读取的文本；支持 UTF-8、带 BOM 的 UTF-16 及 GB18030 文本。")
        }
        return result
    }

    private static func checked(_ text: String) throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw APIError.provider("文件没有可提取的文字；扫描件请使用图片或 PDF。") }
        guard text.utf8.count <= 1024 * 1024 else { throw APIError.provider("提取的文字超过 1 MB，请拆分文档后上传。") }
        return text
    }

    private static func office(_ data: Data, ext: String) throws -> String {
        let zip = try DocumentZip(data)
        var parts: [String] = []
        switch ext {
        case "docx":
            parts.append(try XMLText.read(zip.file("word/document.xml")))
            for name in zip.names.sorted() where name.hasPrefix("word/") && (name.contains("header") || name.contains("footer") || name.hasSuffix("footnotes.xml")) && name.hasSuffix(".xml") {
                parts.append(try XMLText.read(zip.file(name)))
            }
        case "pptx":
            let names = zip.names.filter { $0.range(of: #"^ppt/slides/slide[0-9]+\.xml$"#, options: .regularExpression) != nil }.sorted(by: naturalOrder)
            for (i, name) in names.enumerated() { parts.append("第 \(i+1) 页\n" + (try XMLText.read(zip.file(name)))) }
        case "xlsx":
            let shared = zip.names.contains("xl/sharedStrings.xml") ? try XMLText.sharedStrings(zip.file("xl/sharedStrings.xml")) : []
            let sheets = zip.names.filter { $0.range(of: #"^xl/worksheets/sheet[0-9]+\.xml$"#, options: .regularExpression) != nil }.sorted(by: naturalOrder)
            for (i, sheet) in sheets.enumerated() { parts.append("工作表 \(i+1)\n" + (try XMLText.sheet(zip.file(sheet), strings: shared))) }
        default: parts.append(try XMLText.read(zip.file("content.xml")))
        }
        return try checked(parts.joined(separator: "\n\n"))
    }
    private static func naturalOrder(_ lhs: String, _ rhs: String) -> Bool { lhs.compare(rhs, options: .numeric) == .orderedAscending }
    private static func htmlText(_ html: String) -> String {
        var text = html.replacingOccurrences(of: #"(?is)<(script|style)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</?(?:p|div|br|li|h[1-6]|tr|section|article)\b[^>]*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: value) }
        return text
    }
}

private final class XMLText: NSObject, XMLParserDelegate {
    var output = ""
    var strings: [String] = []
    var shared: [String] = []
    var mode = "text"
    var current = ""
    var cellType = ""
    var inValue = false
    var inText = false
    var column = 0
    var outputTooLarge = false
    static func read(_ data: Data) throws -> String { try parse(data).output }
    static func sharedStrings(_ data: Data) throws -> [String] { try parse(data, mode: "strings").strings }
    static func sheet(_ data: Data, strings: [String]) throws -> String { try parse(data, mode: "sheet", strings: strings).output }
    static func parse(_ data: Data, mode: String = "text", strings: [String] = []) throws -> XMLText {
        // Office XML does not require DTDs; reject entity declarations altogether.
        guard data.range(of: Data("<!DOCTYPE".utf8)) == nil, data.range(of: Data("<!ENTITY".utf8)) == nil else { throw APIError.provider("不支持包含实体声明的文档。") }
        let delegate = XMLText(); delegate.mode = mode; delegate.shared = strings
        let parser = XMLParser(data: data); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.outputTooLarge else { throw APIError.provider("文档结构损坏或提取的文字过多。") }
        return delegate
    }
    private func local(_ element: String) -> String { element.components(separatedBy: ":").last ?? element }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        let name = local(elementName)
        if mode == "sheet" {
            if name == "row" { column = 0 }
            if name == "c" {
                current = ""; cellType = attributes["t"] ?? ""
                if let reference = attributes["r"] {
                    let letters = reference.uppercased().utf8.prefix(while: { (65...90).contains($0) })
                    let target = letters.reduce(0) { min(16384, $0 * 26 + Int($1) - 64) } - 1
                    if target >= column { output += String(repeating: "\t", count: target - column); column = target }
                }
            }
            if name == "v" || name == "t" { inValue = true }
        } else if mode == "strings" {
            if name == "si" { current = "" }
            if name == "t" { inText = true }
        } else {
            if name == "t" || ["p", "h", "span"].contains(name) { inText = true }
            if name == "tab" { output += "\t" }
            if name == "br" || name == "line-break" { output += "\n" }
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if mode == "sheet", inValue { current += string }
        else if mode == "strings", inText { current += string }
        else if mode == "text", inText { output += string }
        if output.utf8.count + current.utf8.count > 1024 * 1024 { outputTooLarge = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = local(elementName)
        if mode == "sheet" {
            if name == "v" || name == "t" { inValue = false }
            if name == "c" {
                if cellType == "s", let index = Int(current), shared.indices.contains(index) { output += shared[index] + "\t" }
                else if cellType == "b" { output += (current == "1" ? "TRUE" : "FALSE") + "\t" }
                else { output += current + "\t" }
                column += 1
            }
            if name == "row" { output += "\n" }
        } else if mode == "strings" {
            if name == "t" { inText = false }
            if name == "si" { strings.append(current) }
        } else {
            if name == "t" { inText = false }
            if ["p", "h", "tr", "table-row"].contains(name) { output += "\n"; inText = false }
            if name == "table-cell" { output += "\t" }
        }
        if output.utf8.count > 1024 * 1024 { outputTooLarge = true; parser.abortParsing() }
    }
}

private struct DocumentZip {
    struct Entry { let flags: Int; let method: Int; let crc: UInt32; let packed: Int; let size: Int; let offset: Int }
    let bytes: Data
    let entries: [String: Entry]
    var names: [String] { Array(entries.keys) }
    init(_ data: Data) throws {
        // Preserve a memory-mapped archive; only selected, bounded XML entries
        // are decompressed. Large embedded media is never copied into an Array.
        let bytes = data
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset + width <= bytes.count else { throw APIError.provider("办公文档压缩结构损坏。") }
            return (0..<width).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard bytes.count >= 22 else { throw APIError.provider("办公文档无法读取。") }
        var end: Int?
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if try number(i, 4) == 0x06054b50, i + 22 + (try number(i + 20, 2)) == bytes.count { end = i; break }
        }
        guard let end, try number(end + 4, 2) == 0, try number(end + 6, 2) == 0 else { throw APIError.provider("不支持分卷、加密或损坏的办公文档。") }
        let count = try number(end + 10, 2)
        guard count < 4096 else { throw APIError.provider("文档内容过多，请拆分后上传。") }
        var offset = try number(end + 16, 4)
        var entries: [String: Entry] = [:]
        var total = 0
        for _ in 0..<count {
            guard try number(offset, 4) == 0x02014b50 else { throw APIError.provider("文档压缩目录损坏。") }
            let length = try number(offset + 28, 2)
            let extra = try number(offset + 30, 2), comment = try number(offset + 32, 2)
            guard offset + 46 + length + extra + comment <= bytes.count else { throw APIError.provider("文档压缩目录不完整。") }
            let name = String(decoding: bytes[(offset+46)..<(offset+46+length)], as: UTF8.self)
            let entry = Entry(flags: try number(offset + 8, 2), method: try number(offset + 10, 2), crc: UInt32(try number(offset + 16, 4)),
                              packed: try number(offset + 20, 4), size: try number(offset + 24, 4), offset: try number(offset + 42, 4))
            if name.hasSuffix(".xml") {
                total += entry.size
                guard entry.size <= 16 * 1024 * 1024, total <= 64 * 1024 * 1024 else { throw APIError.provider("文档正文解压内容过大，请拆分后上传。") }
            }
            entries[name] = entry; offset += 46 + length + extra + comment
        }
        self.bytes = bytes; self.entries = entries
    }
    func file(_ name: String) throws -> Data {
        guard let entry = entries[name], entry.flags & 1 == 0, [0, 8].contains(entry.method) else { throw APIError.provider("文档缺少正文、已加密或压缩方式不支持。") }
        guard entry.size <= 16 * 1024 * 1024, entry.packed <= 32 * 1024 * 1024 else { throw APIError.provider("文档正文过大，请拆分后上传。") }
        func number(_ offset: Int, _ width: Int) throws -> Int {
            guard offset >= 0, offset + width <= bytes.count else { throw APIError.provider("文档数据损坏。") }
            return (0..<width).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        guard try number(entry.offset, 4) == 0x04034b50 else { throw APIError.provider("文档正文损坏。") }
        let start = try entry.offset + 30 + number(entry.offset + 26, 2) + number(entry.offset + 28, 2)
        guard start >= 0, start + entry.packed <= bytes.count else { throw APIError.provider("文档正文不完整。") }
        let packed = Array(bytes[start..<(start + entry.packed)])
        var output = [UInt8](repeating: 0, count: max(1, entry.size))
        if entry.method == 0 { guard packed.count == entry.size else { throw APIError.malformedResponse }; output = packed }
        else {
            var stream = z_stream()
            guard inflateInit2_(&stream, -MAX_WBITS, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw APIError.malformedResponse }
            defer { inflateEnd(&stream) }
            let status = packed.withUnsafeBytes { input in
                output.withUnsafeMutableBytes { destination in
                    stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                    stream.avail_in = uInt(packed.count)
                    stream.next_out = destination.bindMemory(to: UInt8.self).baseAddress
                    stream.avail_out = uInt(destination.count)
                    return inflate(&stream, Z_FINISH)
                }
            }
            guard status == Z_STREAM_END, stream.total_out == entry.size else { throw APIError.provider("办公文档解压失败。") }
            output = Array(output.prefix(entry.size))
        }
        let crc = output.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
        guard crc == entry.crc else { throw APIError.provider("办公文档校验失败，请重新导出文件。") }
        return Data(output)
    }
}
