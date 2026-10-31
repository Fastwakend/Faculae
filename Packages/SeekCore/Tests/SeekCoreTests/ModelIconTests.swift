import XCTest
import Foundation
@testable import SeekCore

final class ModelIconTests: XCTestCase {
    func testOlderModelAndMessageJSONWithoutIconFieldsStillLoads() throws {
        let profile = APIProfile(name: "Gemini", provider: .gemini)
        let model = try JSONDecoder().decode(APIModel.self, from: JSONEncoder().encode(profile.selectedModel))
        XCTAssertNil(model.iconStyle)
        XCTAssertNil(model.customIconID)
        let message = ChatMessage(role: .assistant, content: "older reply", model: "gemini-2.5-flash")
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(message))
        XCTAssertNil(decoded.modelIconStyle)
        XCTAssertNil(decoded.modelProvider)
        XCTAssertNil(decoded.customIconID)
        let old = Data(#"{"id":"93BA4573-352A-48DC-BBD9-1A99B54C358A","name":"DeepSeek","provider":"openAI","baseURL":"https://api.deepseek.com","model":"deepseek-chat"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(APIProfile.self, from: old).selectedModel.iconStyle)
    }

    func testIconChoicesAreIndependentAndSurviveProfileRoundTrip() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let first = profile.selectedModelID
        let second = try profile.addModel("custom-chat")
        var firstModel = profile.selectedModel
        firstModel.iconStyle = .claude
        try profile.updateModel(firstModel)
        profile.selectModel(second)
        var custom = profile.selectedModel
        custom.iconStyle = .custom
        custom.customIconID = UUID()
        try profile.updateModel(custom)
        let restored = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        XCTAssertEqual(restored.selectedModel.customIconID, custom.customIconID)
        profile.selectModel(first)
        XCTAssertEqual(profile.selectedModel.iconStyle, .claude)
        XCTAssertNil(profile.selectedModel.customIconID)
        try profile.removeModel(second)
        XCTAssertEqual(profile.selectedModel.iconStyle, .claude)
        for style in ModelIconStyle.allCases {
            var entry = firstModel
            entry.iconStyle = style
            XCTAssertEqual(try JSONDecoder().decode(APIModel.self, from: JSONEncoder().encode(entry)), entry)
        }
    }

    func testReplyRetainsItsOwnIconWhenModelIconIsChangedOrDeleted() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let id = try profile.addModel("custom-chat")
        profile.selectModel(id)
        var model = profile.selectedModel
        model.iconStyle = .custom
        model.customIconID = UUID()
        try profile.updateModel(model)
        let message = ChatMessage(role: .assistant, content: "reply", model: model.model,
                                  modelProvider: profile.provider, modelIconStyle: model.iconStyle,
                                  customIconID: model.customIconID)
        let saved = Conversation(profileID: profile.id, messages: [message], modelID: id)
        model.iconStyle = .gemini
        model.customIconID = nil
        try profile.updateModel(model)
        try profile.removeModel(id)
        let restored = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.messages[0].customIconID, message.customIconID)
        XCTAssertEqual(restored.messages[0].modelIconStyle, .custom)
        XCTAssertEqual(restored.messages[0].modelProvider, .openAI)
    }

    func testIconMetadataNeverEntersAnyProviderRequest() throws {
        let iconID = UUID()
        for provider in APIProvider.allCases {
            var profile = APIProfile(name: "Test", provider: provider)
            var model = profile.selectedModel
            let originalMessages = [ChatMessage(role: .user, content: "hello"),
                                    ChatMessage(role: .assistant, content: "reply", model: model.model),
                                    ChatMessage(role: .user, content: "continue")]
            let original = try RequestBuilder.chat(profile: profile, key: "test-key", messages: originalMessages)
            model.iconStyle = .custom
            model.customIconID = iconID
            try profile.updateModel(model)
            var decoratedMessages = originalMessages
            decoratedMessages[1].modelIconStyle = .custom
            decoratedMessages[1].customIconID = iconID
            decoratedMessages[1].modelProvider = provider
            let decorated = try RequestBuilder.chat(profile: profile, key: "test-key", messages: decoratedMessages)
            let originalBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(original.httpBody)) as? NSDictionary)
            let decoratedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(decorated.httpBody)) as? NSDictionary)
            XCTAssertEqual(originalBody, decoratedBody)
            XCTAssertEqual(original.url, decorated.url)
            XCTAssertFalse(String(decoding: try XCTUnwrap(decorated.httpBody), as: UTF8.self).contains(iconID.uuidString))
        }
    }
}
