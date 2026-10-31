import XCTest
@testable import SeekCore

final class ReferenceBranchHapticsTests: XCTestCase {
    private func imageProfile(_ provider: APIProvider) throws -> APIProfile {
        var profile = APIProfile(name: "Images", provider: provider, model: "image-model")
        var model = profile.selectedModel; model.modelType = .imageGeneration
        try profile.updateModel(model)
        return profile
    }
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testOpenAIReferencesUseMultipartEditsWithExactBinaryAndParameters() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data((0..<400_003).map { UInt8($0 % 256) })
        let image = ChatAttachment(name: "untrusted\"\r\nname.jpg", mimeType: "image/jpeg", kind: .image, byteCount: bytes.count)
        let file = folder.appendingPathComponent(image.id.uuidString); try bytes.write(to: file)
        let body = folder.appendingPathComponent("request")
        var profile = try imageProfile(.openAI)
        profile.baseURL = "https://example.com/v1/images/edits"
        let request = try ImageGenerationAPI.request(profile: profile, key: "k", prompt: "保留构图\n改变颜色",
            attachments: [image], attachmentFiles: [image.id: file], bodyFile: body)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/images/edits")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        XCTAssertNil(request.httpBody)
        let data = try Data(contentsOf: body)
        XCTAssertNotNil(data.range(of: bytes))
        for field in ["model", "prompt", "size", "quality", "output_format", "background", "moderation", "image[]"] {
            XCTAssertNotNil(data.range(of: Data("name=\"\(field)\"".utf8)))
        }
        XCTAssertNil(data.range(of: Data(image.name.utf8)))
        XCTAssertNotNil(data.range(of: Data("保留构图\n改变颜色".utf8)))
    }

    func testGeminiReferencesStreamInlineBase64AcrossChunkBoundaries() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = Data((0..<400_003).map { UInt8($0 % 251) })
        let image = ChatAttachment(name: "reference.png", mimeType: "image/png", kind: .image, byteCount: bytes.count)
        let file = folder.appendingPathComponent(image.id.uuidString); try bytes.write(to: file)
        let body = folder.appendingPathComponent("request")
        let request = try ImageGenerationAPI.request(profile: imageProfile(.gemini), key: "k", prompt: "结合参考图",
            attachments: [image], attachmentFiles: [image.id: file], bodyFile: body)
        XCTAssertTrue(request.url!.absoluteString.hasSuffix(":generateContent"))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: body)) as! [String: Any]
        let parts = (json["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]]
        let inline = parts[1]["inlineData"] as! [String: Any]
        XCTAssertEqual(inline["mimeType"] as? String, "image/png")
        XCTAssertEqual(Data(base64Encoded: inline["data"] as! String), bytes)
        XCTAssertTrue((parts[0]["text"] as! String).contains("结合参考图"))
        XCTAssertNil(request.httpBody)
    }

    func testReferenceOnlyRequestUsesDefaultPromptAndMissingOrNonImageFails() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("image"); try Data([1, 2, 3]).write(to: file)
        let image = ChatAttachment(name: "reference.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 3)
        let profile = try imageProfile(.openAI), body = folder.appendingPathComponent("body")
        _ = try ImageGenerationAPI.request(profile: profile, key: "k", prompt: "", attachments: [image],
            attachmentFiles: [image.id: file], bodyFile: body)
        XCTAssertTrue(try String(contentsOf: body, encoding: .utf8).contains("请参考上传的图片生成图像。"))
        XCTAssertThrowsError(try ImageGenerationAPI.request(profile: profile, key: "k", prompt: "x", attachments: [image], bodyFile: body))
        let pdf = ChatAttachment(name: "x.pdf", mimeType: "application/pdf", kind: .pdf, byteCount: 3)
        XCTAssertThrowsError(try ImageGenerationAPI.validateReferences([pdf]))
        XCTAssertThrowsError(try ImageGenerationAPI.validateReferences(Array(repeating: image, count: 7)))
    }

    func testFailedMultipartWriteRemovesPartialRequest() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("request")
        let image = ChatAttachment(name: "missing.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 2)
        XCTAssertThrowsError(try MultipartFileWriter.write(fields: ["prompt": "x"], images: [image], files: [:], boundary: "test", to: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testBranchIncludesNodePreservesContextAndHasIndependentMessageIDs() throws {
        let attachment = ChatAttachment(name: "reference.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 3)
        let user = ChatMessage(role: .user, content: "original prompt", attachments: [attachment])
        var assistant = ChatMessage(role: .assistant, content: "answer", reasoning: "reasoning", model: "model")
        assistant.imageGenerationSettings = ImageGenerationSettings()
        let source = Conversation(title: "Original", profileID: UUID(), messages: [user, assistant, ChatMessage(role: .user, content: "later")], modelID: UUID())
        var branch = try source.branched(through: assistant.id)
        XCTAssertEqual(branch.messages.count, 2)
        XCTAssertEqual(branch.messages.map(\.content), ["original prompt", "answer"])
        XCTAssertEqual(branch.messages[1].reasoning, "reasoning")
        XCTAssertEqual(branch.messages[1].imageGenerationSettings, assistant.imageGenerationSettings)
        XCTAssertEqual(branch.messages[0].attachments?.first?.id, attachment.id)
        XCTAssertTrue(Set(branch.messages.map(\.id)).isDisjoint(with: source.messages.map(\.id)))
        XCTAssertNotEqual(branch.id, source.id)
        XCTAssertEqual(branch.parentConversationID, source.id); XCTAssertEqual(branch.parentMessageID, assistant.id)
        XCTAssertEqual(branch.modelID, source.modelID)
        branch.messages[0].content = "independent edit"
        XCTAssertEqual(source.messages[0].content, "original prompt")
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(branch)), branch)
    }

    func testBranchUserNodeStreamingSnapshotAndLegacyDecode() throws {
        let user = ChatMessage(role: .user, content: "prompt")
        var streaming = ChatMessage(role: .assistant, content: "partial", status: .streaming)
        streaming.generationStage = "receiving"
        let source = Conversation(profileID: UUID(), messages: [user, streaming])
        XCTAssertEqual(try source.branched(through: user.id).messages.count, 1)
        let branch = try source.branched(through: streaming.id)
        XCTAssertEqual(branch.messages.last?.status, .stopped)
        XCTAssertNil(branch.messages.last?.generationStage)
        XCTAssertEqual(source.messages.last?.status, .streaming)
        XCTAssertThrowsError(try source.branched(through: UUID()))
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        json.removeValue(forKey: "parentConversationID"); json.removeValue(forKey: "parentMessageID")
        XCTAssertNil(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: json)).parentConversationID)
    }

    func testDeletingOriginalAndBranchDoesNotRemoveSharedImagesEarly() throws {
        let attachment = ChatAttachment(name: "generated.png", mimeType: "image/png", kind: .image, byteCount: 8)
        let message = ChatMessage(role: .assistant, content: "image", attachments: [attachment])
        let source = Conversation(profileID: UUID(), messages: [message])
        let branch = try source.branched(through: message.id)
        var chats = [source, branch]
        XCTAssertTrue(ConversationBatchActions.remove([source.id], from: &chats).isEmpty)
        XCTAssertEqual(ConversationBatchActions.remove([branch.id], from: &chats).map(\.id), [attachment.id])
    }

    func testHapticMasterAndCategoryGatesRoundTrip() throws {
        var settings = HapticPreferences()
        XCTAssertTrue(HapticCategory.allCases.allSatisfy(settings.allows))
        settings.cards = false; settings.switches = false
        XCTAssertFalse(settings.allows(.card)); XCTAssertFalse(settings.allows(.switches))
        XCTAssertTrue(settings.allows(.sidebar)); XCTAssertTrue(settings.allows(.generation))
        settings.enabled = false
        XCTAssertFalse(HapticCategory.allCases.contains(where: settings.allows))
        settings.enabled = true
        XCTAssertFalse(settings.allows(.card))
        XCTAssertEqual(try JSONDecoder().decode(HapticPreferences.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testZeroIntensityMutesAllCategoriesAndInvalidIntensityIsBounded() {
        var settings = HapticPreferences(); settings.intensity = 0
        XCTAssertFalse(HapticCategory.allCases.contains(where: settings.allows))
        settings.intensity = -2; XCTAssertEqual(settings.effectiveIntensity, 0)
        settings.intensity = 2; XCTAssertEqual(settings.effectiveIntensity, 1)
        settings.intensity = .nan; XCTAssertEqual(settings.effectiveIntensity, 0.6)
    }
}
