import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SeekCore

final class MultimodalTests: XCTestCase {
    private func json(_ profile: APIProfile, _ messages: [ChatMessage] = [ChatMessage(role: .user, content: "hello")], data: [UUID: Data] = [:]) throws -> [String: Any] {
        let request = try RequestBuilder.chat(profile: profile, key: "test-not-secret", messages: messages, attachmentData: data)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testOldSavedProfilesAndMessagesStillDecode() throws {
        let profile = APIProfile.presets[0]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        saved.removeValue(forKey: "reasoningLevel")
        let decoded = try JSONDecoder().decode(APIProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(decoded.id, profile.id)
        XCTAssertNil(decoded.reasoningLevel)
        let message = ChatMessage(role: .user, content: "old chat")
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        old.removeValue(forKey: "attachments")
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONSerialization.data(withJSONObject: old)), message)
    }

    func testOpenAIReasoningAndLegacyAutomaticDefault() throws {
        var profile = APIProfile(name: "test", provider: .openAI, model: "o3-mini", reasoningLevel: .high)
        XCTAssertEqual(try json(profile)["reasoning_effort"] as? String, "high")
        profile.reasoningLevel = .automatic
        XCTAssertNil(try json(profile)["reasoning_effort"])
        profile.model = "gpt-4.1-mini"; profile.reasoningLevel = .high
        XCTAssertEqual(try json(profile)["reasoning_effort"] as? String, "high")
    }

    func testCompatibleClaudeUsesCompatibleEffort() throws {
        let profile = APIProfile(name: "Claude relay", provider: .openAI, model: "claude-opus-5-5", reasoningLevel: .medium)
        let body = try json(profile)
        XCTAssertEqual(body["reasoning_effort"] as? String, "medium")
        XCTAssertNil(body["thinking"])
    }

    func testGeminiBudgetAndExactMediumLevel() throws {
        var profile = APIProfile(name: "g", provider: .gemini, maxOutputTokens: 4096, reasoningLevel: .high)
        let generation = try XCTUnwrap(json(profile)["generationConfig"] as? [String: Any])
        XCTAssertEqual((generation["thinkingConfig"] as? [String: Int])?["thinkingBudget"], 4095)
        profile.reasoningLevel = .medium
        XCTAssertEqual(profile.reasoningBudget, 2048)
        profile.reasoningLevel = .low
        XCTAssertEqual(profile.reasoningBudget, 1024)
        profile.model = "gemini-3-pro-preview"; profile.reasoningLevel = .medium
        let newer = try XCTUnwrap(json(profile)["generationConfig"] as? [String: Any])
        XCTAssertEqual((newer["thinkingConfig"] as? [String: String])?["thinkingLevel"], "MEDIUM")
    }

    func testClaudeAdaptiveAndLegacyBudgets() throws {
        var profile = APIProfile(name: "c", provider: .claude, model: "claude-opus-5-5", sendsTemperature: true, reasoningLevel: .low)
        var body = try json(profile)
        XCTAssertEqual((body["thinking"] as? [String: String])?["type"], "adaptive")
        XCTAssertEqual((body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertNil(body["temperature"])
        profile.model = "claude-sonnet-4-5"; profile.reasoningLevel = .high
        body = try json(profile)
        let thinking = try XCTUnwrap(body["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["budget_tokens"] as? Int, 2559)
        profile.maxOutputTokens = 1024
        XCTAssertThrowsError(try json(profile))
    }

    func testAttachmentOnlyMessagesSerializeForAllProviders() throws {
        let image = ChatAttachment(name: "photo.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 3)
        let pdf = ChatAttachment(name: "doc.pdf", mimeType: "application/pdf", kind: .pdf, byteCount: 4)
        let message = ChatMessage(role: .user, attachments: [image, pdf])
        XCTAssertTrue(message.isValidContext)
        let bytes = [image.id: Data([1, 2, 3]), pdf.id: Data("%PDF".utf8)]
        for provider in APIProvider.allCases {
            let body = try json(APIProfile(name: "test", provider: provider), [message], data: bytes)
            let turns = try XCTUnwrap(body[provider == .gemini ? "contents" : "messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(turns[0][provider == .gemini ? "parts" : "content"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 2)
            switch provider {
            case .openAI:
                XCTAssertEqual(parts[0]["type"] as? String, "image_url")
                XCTAssertEqual((parts[0]["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AQID")
                XCTAssertEqual((parts[1]["file"] as? [String: String])?["filename"], "doc.pdf")
            case .gemini:
                XCTAssertEqual((parts[0]["inlineData"] as? [String: String])?["mimeType"], "image/jpeg")
                XCTAssertEqual((parts[1]["inlineData"] as? [String: String])?["mimeType"], "application/pdf")
            case .claude:
                XCTAssertEqual(parts[0]["type"] as? String, "image")
                XCTAssertEqual(parts[1]["type"] as? String, "document")
                XCTAssertEqual((parts[1]["source"] as? [String: String])?["data"], Data("%PDF".utf8).base64EncodedString())
            }
        }
    }

    func testMergingConsecutiveUsersPreservesBothAttachments() throws {
        let a = ChatAttachment(name: "a.txt", mimeType: "text/plain", kind: .text, byteCount: 1)
        let b = ChatAttachment(name: "b.txt", mimeType: "text/plain", kind: .text, byteCount: 1)
        let messages = [ChatMessage(role: .user, attachments: [a]), ChatMessage(role: .assistant, status: .failed), ChatMessage(role: .user, attachments: [b])]
        let body = try json(APIProfile(name: "g", provider: .gemini), messages, data: [a.id: Data("A".utf8), b.id: Data("B".utf8)])
        let turns = try XCTUnwrap(body["contents"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 1)
        let parts = try XCTUnwrap(turns[0]["parts"] as? [[String: String]])
        XCTAssertTrue(parts.contains { $0["text"]?.contains("a.txt\n\nA") == true })
        XCTAssertTrue(parts.contains { $0["text"]?.contains("b.txt\n\nB") == true })
    }

    func testMissingAttachmentsFailAndPreviousEightMegabyteLimitIsRemoved() throws {
        let image = ChatAttachment(name: "photo.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 1)
        let message = ChatMessage(role: .user, attachments: [image])
        let profile = APIProfile(name: "o", provider: .openAI)
        XCTAssertThrowsError(try json(profile, [message]))
        XCTAssertNoThrow(try json(profile, [message], data: [image.id: Data(count: 8 * 1024 * 1024 + 1)]))
    }

    func testDeepSeekFlashImagesAreSentWithoutModelNameBasedRejection() throws {
        let image = ChatAttachment(name: "拍摄照片.jpg", mimeType: "image/jpeg", kind: .image, byteCount: 3)
        let message = ChatMessage(role: .user, content: "描述图片", attachments: [image])
        for model in ["deepseek-flash", "DeepSeek-Flash", "deepseek-v4-flash"] {
            let profile = APIProfile(name: "DeepSeek", provider: .openAI, model: model)
            let body = try json(profile, [message], data: [image.id: Data([1, 2, 3])])
            XCTAssertEqual(body["model"] as? String, model)
            let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
            let parts = try XCTUnwrap(turns[0]["content"] as? [[String: Any]])
            XCTAssertEqual(parts.last?["type"] as? String, "image_url")
            XCTAssertEqual((parts.last?["image_url"] as? [String: String])?["url"], "data:image/jpeg;base64,AQID")
        }
    }
}
