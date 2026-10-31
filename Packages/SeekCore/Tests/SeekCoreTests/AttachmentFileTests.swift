import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SeekCore

final class AttachmentFileTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sparse(_ url: URL, bytes: Int) throws {
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(bytes))
    }

    func testOneGigabyteBoundaryWithoutAllocatingGigabyteData() throws {
        let file = try folder().appendingPathComponent("boundary.pdf")
        try sparse(file, bytes: AttachmentLimits.fileBytes)
        XCTAssertEqual(try AttachmentFileIO.size(file), 1_073_741_824)
        try sparse(file, bytes: AttachmentLimits.fileBytes + 1)
        XCTAssertThrowsError(try AttachmentFileIO.size(file))
    }

    func testChunkedCopySurvivesOriginalRemoval() throws {
        let root = try folder(), source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("copied")
        let data = Data((0..<(AttachmentFileIO.chunkBytes * 3 + 5)).map { UInt8($0 % 251) })
        try data.write(to: source)
        XCTAssertEqual(try AttachmentFileIO.copy(source, to: destination), data.count)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: destination), data)
    }

    func testCancelledCopyLeavesNoDestinationOrPartialFile() throws {
        let root = try folder(), source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("cancelled")
        try Data(repeating: 7, count: 300_000).write(to: source)
        XCTAssertThrowsError(try AttachmentFileIO.copy(source, to: destination, isCancelled: { true }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["source"])
    }

    func testUTF8AcrossChunksAndInvalidSequences() throws {
        var validator = AttachmentUTF8Validator()
        for byte in Data("中文😀\n\tline".utf8) { try validator.append(Data([byte])) }
        try validator.finish()
        let invalidSequences: [[UInt8]] = [[0xC0,0x80],[0xED,0xA0,0x80],[0xF4,0x90,0x80,0x80],[0],[0xE2,0x82]]
        for bytes in invalidSequences {
            var invalid = AttachmentUTF8Validator()
            XCTAssertThrowsError(try { try invalid.append(Data(bytes)); try invalid.finish() }())
        }
    }

    func testFileBackedProviderBodiesMatchExistingMultimodalContracts() throws {
        let root = try folder()
        let values: [(ChatAttachment.Kind, String, Data)] = [
            (.image,"image/jpeg",Data((0..<(AttachmentFileIO.chunkBytes + 5)).map { UInt8($0 % 251) })),
            (.pdf,"application/pdf",Data("%PDF-test/quoted\\\"".utf8)),
            (.text,"text/plain",Data("中文😀\n\"quoted\"\\path\r\ttext".utf8))]
        var attachments: [ChatAttachment] = [], data: [UUID: Data] = [:], files: [UUID: URL] = [:]
        for (kind,mime,bytes) in values {
            let attachment = ChatAttachment(name: "file-\"\(kind.rawValue)", mimeType: mime, kind: kind, byteCount: bytes.count)
            let url = root.appendingPathComponent(attachment.id.uuidString); try bytes.write(to: url)
            attachments.append(attachment); data[attachment.id] = bytes; files[attachment.id] = url
        }
        let messages = [ChatMessage(role: .user, content: "explain \"all\"", attachments: attachments)]
        for provider in APIProvider.allCases {
            let profile = APIProfile(name: "test", provider: provider)
            let expected = try RequestBuilder.chat(profile: profile, key: "test-key", messages: messages, attachmentData: data)
            let output = root.appendingPathComponent(provider.rawValue + ".json")
            let actual = try RequestBuilder.chat(profile: profile, key: "test-key", messages: messages, attachmentFiles: files, bodyFile: output)
            XCTAssertNil(actual.httpBody); XCTAssertEqual(actual.url, expected.url)
            let expectedJSON = try JSONSerialization.jsonObject(with: XCTUnwrap(expected.httpBody)) as! NSDictionary
            let actualData = try Data(contentsOf: output)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: actualData) as? NSDictionary, expectedJSON)
            XCTAssertEqual(actual.value(forHTTPHeaderField: "Content-Length"), String(actualData.count))
        }
    }

    func testLargeUTF8TextStreamsAndPreservesEscaping() throws {
        let root = try folder(), source = root.appendingPathComponent("text.txt"), output = root.appendingPathComponent("body.json")
        let text = String(repeating: "中文😀\"\\\n", count: 120_000)
        try Data(text.utf8).write(to: source)
        let attachment = ChatAttachment(name: "text.txt", mimeType: "text/plain", kind: .text, byteCount: text.utf8.count)
        let request = try RequestBuilder.chat(profile: APIProfile.presets[0], key: "test-key",
            messages: [ChatMessage(role: .user, attachments: [attachment])], attachmentFiles: [attachment.id:source], bodyFile: output)
        XCTAssertNil(request.httpBody)
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as! [String:Any]
        let messages = body["messages"] as! [[String:Any]]
        let parts = messages.last!["content"] as! [[String:Any]]
        XCTAssertEqual(parts.last!["text"] as? String, "附件：text.txt\n\n" + text)
    }

    func testInvalidTextRemovesPartialJSONAndOversizeIsRejectedBeforeWriting() throws {
        let root = try folder(), source = root.appendingPathComponent("bad"), output = root.appendingPathComponent("body.json")
        try Data([0xF0,0x9F]).write(to: source)
        XCTAssertThrowsError(try FileJSONWriter.write(["text":JSONFileString(url: source, encoding: .text)], to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        try sparse(source, bytes: AttachmentLimits.fileBytes + 1)
        let attachment = ChatAttachment(name: "big.pdf", mimeType: "application/pdf", kind: .pdf, byteCount: AttachmentLimits.fileBytes + 1)
        XCTAssertThrowsError(try RequestBuilder.chat(profile: APIProfile.presets[0], key: "test-key",
            messages: [ChatMessage(role:.user, attachments:[attachment])], attachmentFiles:[attachment.id:source], bodyFile:output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
