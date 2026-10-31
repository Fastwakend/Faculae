import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SeekCore

final class ProfileModelsTests: XCTestCase {
    func testLegacySupplierMigratesWithoutChangingKeychainIdentityOrModelSettings() throws {
        let data = Data(#"{"id":"93BA4573-352A-48DC-BBD9-1A99B54C358A","name":"My relay","provider":"openAI","baseURL":"https://relay.example/v1","model":"claude-opus-5-5","systemPrompt":"Keep this","temperature":0.3,"sendsTemperature":true,"maxOutputTokens":8192,"reasoningLevel":"max"}"#.utf8)
        let profile = try JSONDecoder().decode(APIProfile.self, from: data)
        XCTAssertEqual(profile.id.uuidString, "93BA4573-352A-48DC-BBD9-1A99B54C358A")
        XCTAssertEqual(profile.models.count, 1)
        XCTAssertEqual(profile.model, "claude-opus-5-5")
        XCTAssertEqual(profile.systemPrompt, "Keep this")
        XCTAssertEqual(profile.temperature, 0.3)
        XCTAssertTrue(profile.sendsTemperature)
        XCTAssertEqual(profile.maxOutputTokens, 8192)
        XCTAssertEqual(profile.reasoningLevel, .max)
        XCTAssertEqual(profile.selectedModelID, profile.models[0].id)
        let encoded = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(APIProfile.self, from: encoded), profile)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).lowercased().contains("apikey"))
    }

    func testModelSwitchUsesSharedConnectionButIndependentRequestParameters() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI, baseURL: "https://relay.example/v1", model: "gpt-6.1-sol", systemPrompt: "First", maxOutputTokens: 8192, reasoningLevel: .max)
        let first = profile.selectedModelID
        let second = try profile.addModel("claude-opus-5-5")
        XCTAssertTrue(profile.selectModel(second))
        profile.systemPrompt = "Second"
        profile.reasoningLevel = .low
        profile.maxOutputTokens = 2048
        let context = [ChatMessage(role: .user, content: "hello")]
        let secondRequest = try RequestBuilder.chat(profile: profile, key: "test-key", messages: context)
        let secondBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(secondRequest.httpBody)) as? [String: Any])
        XCTAssertEqual(secondRequest.url?.absoluteString, "https://relay.example/v1/chat/completions")
        XCTAssertEqual(secondRequest.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(secondBody["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(secondBody["reasoning_effort"] as? String, "low")
        XCTAssertEqual(secondBody["max_tokens"] as? Int, 2048)
        XCTAssertTrue(profile.selectModel(first))
        let request = try RequestBuilder.chat(profile: profile, key: "test-key", messages: context)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(request.url, secondRequest.url)
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["reasoning_effort"] as? String, "max")
        XCTAssertEqual(body["max_completion_tokens"] as? Int, 8192)
        XCTAssertEqual(profile.systemPrompt, "First")
    }

    func testMultipleModelsAndSelectionSurviveSavingAndReloading() throws {
        var profile = APIProfile(name: "DeepSeek", provider: .openAI, model: "deepseek-chat", reasoningLevel: .off)
        let second = try profile.addModel("deepseek-reasoner")
        profile.selectModel(second)
        profile.reasoningLevel = .high
        let reloaded = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(reloaded, profile)
        XCTAssertEqual(reloaded.model, "deepseek-reasoner")
        XCTAssertEqual(reloaded.reasoningLevel, .high)
        XCTAssertEqual(reloaded.models[0].reasoningLevel, .off)
    }

    func testDuplicateAndBlankModelAdditionsDoNotModifySupplier() throws {
        var profile = APIProfile(name: "Gemini", provider: .gemini, model: "gemini-3-flash")
        let original = profile
        XCTAssertThrowsError(try profile.addModel(" models/gemini-3-flash \n"))
        XCTAssertThrowsError(try profile.addModel(" \n"))
        XCTAssertEqual(profile, original)
        try profile.addModel(" models/gemini-3-pro ")
        XCTAssertEqual(profile.models.last?.model, "gemini-3-pro")
        XCTAssertEqual(profile.selectedModelID, original.selectedModelID)
    }

    func testDeletingSelectedModelFallsBackAndLastModelIsProtected() throws {
        var profile = APIProfile(name: "OpenAI", provider: .openAI)
        let first = profile.selectedModelID
        let second = try profile.addModel("gpt-6.1-sol")
        profile.selectModel(second)
        try profile.removeModel(second)
        XCTAssertEqual(profile.selectedModelID, first)
        XCTAssertThrowsError(try profile.removeModel(first))
        XCTAssertFalse(profile.selectModel(UUID()))
        XCTAssertEqual(profile.models.count, 1)
        XCTAssertEqual(profile.selectedModelID, first)
    }

    func testEditedModelKeepsStableIdentityAndRejectsDuplicateIDs() throws {
        var profile = APIProfile(name: "OpenAI", provider: .openAI)
        let first = profile.selectedModelID
        let second = try profile.addModel("gpt-6.1-sol")
        var edited = try XCTUnwrap(profile.models.first { $0.id == second })
        edited.model = profile.model
        XCTAssertThrowsError(try profile.updateModel(edited))
        edited.model = "gpt-6-sol"
        edited.maxOutputTokens = 16384
        try profile.updateModel(edited)
        XCTAssertEqual(profile.selectedModelID, first)
        profile.selectModel(second)
        XCTAssertEqual(profile.model, "gpt-6-sol")
        XCTAssertEqual(profile.maxOutputTokens, 16384)
    }

    func testSaveValidationChecksInactiveModelsToo() throws {
        var profile = APIProfile(name: "Gemini", provider: .gemini)
        try profile.addModel("bad/model?path")
        XCTAssertNoThrow(try RequestBuilder.validate(profile))
        XCTAssertThrowsError(try RequestBuilder.validateAllModels(profile))
    }

    func testConversationRestoresItsOwnModelAndHandlesDeletedModels() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let first = profile.selectedModelID
        let second = try profile.addModel("gpt-6.1-sol")
        let conversation = Conversation(profileID: profile.id, messages: [ChatMessage(role: .assistant, content: "ok", model: "gpt-6.1-sol")], modelID: second)
        let saved = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(conversation))
        XCTAssertTrue(profile.restoreModel(for: saved))
        XCTAssertEqual(profile.selectedModelID, second)
        try profile.removeModel(second)
        XCTAssertFalse(profile.restoreModel(for: saved))
        XCTAssertEqual(profile.selectedModelID, first)
        XCTAssertFalse(profile.restoreModel(for: Conversation(profileID: UUID(), modelID: first)))
    }

    func testLegacyConversationFindsModelFromItsLastAssistantReply() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI)
        let second = try profile.addModel("gpt-6.1-sol")
        let chat = Conversation(profileID: profile.id, messages: [ChatMessage(role: .assistant, content: "old", model: "gpt-6.1-sol")])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(chat)) as? [String: Any])
        object.removeValue(forKey: "modelID")
        let decoded = try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.modelID)
        XCTAssertTrue(profile.restoreModel(for: decoded))
        XCTAssertEqual(profile.selectedModelID, second)
    }

    func testCorruptEmptyCollectionFailsInsteadOfResettingSavedModels() throws {
        let original = APIProfile(name: "OpenAI", provider: .openAI)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object["models"] = []
        XCTAssertThrowsError(try JSONDecoder().decode(APIProfile.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
