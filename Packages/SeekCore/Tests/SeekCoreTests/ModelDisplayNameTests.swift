import XCTest
import Foundation
@testable import SeekCore

final class ModelDisplayNameTests: XCTestCase {
    func testLegacyModelsAndRepliesFallBackToTheirAPIModelNames() throws {
        let model = APIModel(model: "deepseek-flash")
        let encoded = try JSONEncoder().encode(model)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["displayName"])
        let restored = try JSONDecoder().decode(APIModel.self, from: encoded)
        XCTAssertNil(restored.displayName)
        XCTAssertEqual(restored.displayTitle, "deepseek-flash")
        let reply = ChatMessage(role: .assistant, content: "old reply", model: model.model)
        let restoredReply = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(reply))
        XCTAssertNil(restoredReply.modelDisplayName)
        XCTAssertEqual(restoredReply.modelDisplayTitle, "deepseek-flash")
        XCTAssertEqual(ChatMessage(role: .assistant).modelDisplayTitle, "助手")
    }

    func testDisplayNamesAreIndependentNormalizedAndPersistedWithoutChangingModelIdentity() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let first = profile.selectedModelID
        let second = try profile.addModel("deepseek-flash")
        var entry = profile.selectedModel
        entry.displayName = "  日常助手 \n"
        entry.reasoningLevel = .high
        try profile.updateModel(entry)
        profile.selectModel(second)
        var other = profile.selectedModel
        other.displayName = "快速回答"
        try profile.updateModel(other)
        var restored = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.selectedModel.displayTitle, "快速回答")
        XCTAssertEqual(restored.model, "deepseek-flash")
        restored.selectModel(first)
        XCTAssertEqual(restored.selectedModel.displayName, "日常助手")
        XCTAssertEqual(restored.selectedModel.id, first)
        XCTAssertEqual(restored.reasoningLevel, .high)
        entry.displayName = " \n "
        try restored.updateModel(entry)
        XCTAssertNil(restored.selectedModel.displayName)
        XCTAssertEqual(restored.selectedModel.displayTitle, restored.model)
    }

    func testDisplayNamesNeverChangeProviderPayloadsURLsOrReasoningFamily() throws {
        for provider in APIProvider.allCases {
            var profile = APIProfile(name: "Test", provider: provider)
            let family = profile.modelFamily
            var messages = [ChatMessage(role: .user, content: "hello"),
                            ChatMessage(role: .assistant, content: "reply", model: profile.model),
                            ChatMessage(role: .user, content: "continue")]
            let original = try RequestBuilder.chat(profile: profile, key: "test-key", messages: messages)
            var entry = profile.selectedModel
            entry.displayName = "Gemini Claude DeepSeek 显示名称"
            try profile.updateModel(entry)
            messages[1].modelDisplayName = entry.displayName
            let renamed = try RequestBuilder.chat(profile: profile, key: "test-key", messages: messages)
            XCTAssertEqual(profile.modelFamily, family)
            XCTAssertEqual(original.url, renamed.url)
            let before = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original.httpBody)) as? NSDictionary)
            let after = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(renamed.httpBody)) as? NSDictionary)
            XCTAssertEqual(before, after)
        }
    }

    func testReplyRetainsSavedDisplayNameAfterModelIsRenamed() throws {
        var profile = APIProfile(name: "OpenAI", provider: .openAI)
        var entry = profile.selectedModel
        entry.displayName = "之前的名字"
        try profile.updateModel(entry)
        let reply = ChatMessage(role: .assistant, content: "reply", model: entry.model, modelDisplayName: entry.displayName)
        let conversation = Conversation(profileID: profile.id, messages: [reply], modelID: entry.id)
        entry.displayName = "新的名字"
        try profile.updateModel(entry)
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertEqual(restored.messages[0].modelDisplayTitle, "之前的名字")
        XCTAssertEqual(restored.messages[0].model, entry.model)
        XCTAssertTrue(profile.restoreModel(for: restored))
        XCTAssertEqual(profile.selectedModel.displayTitle, "新的名字")
    }

    func testSharedDisplayNamesDoNotReplaceAPIModelIDUniqueness() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let otherID = try profile.addModel("another-model")
        for item in profile.models {
            var edited = item
            edited.displayName = "我的助手"
            try profile.updateModel(edited)
        }
        XCTAssertNoThrow(try RequestBuilder.validateAllModels(profile))
        var duplicate = try XCTUnwrap(profile.models.first { $0.id == otherID })
        duplicate.model = profile.model
        duplicate.displayName = "另一个显示名"
        XCTAssertThrowsError(try profile.updateModel(duplicate))
    }
}
