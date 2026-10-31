import XCTest
@testable import SeekCore

final class ListOrderingTests: XCTestCase {
    func testMultipleRowsMoveInBothDirectionsWithOriginalDestinationOffsets() {
        var values = ["a", "b", "c", "d", "e"]
        XCTAssertTrue(ListOrdering.move(&values, fromOffsets: IndexSet([1, 3]), toOffset: 5))
        XCTAssertEqual(values, ["a", "c", "e", "b", "d"])
        XCTAssertTrue(ListOrdering.move(&values, fromOffsets: IndexSet([3, 4]), toOffset: 0))
        XCTAssertEqual(values, ["b", "d", "a", "c", "e"])
    }

    func testInvalidAndUnchangedMovesDoNotMutateTheCollection() {
        var values = [10, 20, 30]
        let original = values
        for (source, destination) in [(IndexSet(), 0), (IndexSet(integer: 8), 0),
            (IndexSet(integer: 0), -1), (IndexSet(integer: 0), 4),
            (IndexSet(integer: 1), 1), (IndexSet(integer: 1), 2), (IndexSet(0..<3), 3)] {
            XCTAssertFalse(ListOrdering.move(&values, fromOffsets: source, toOffset: destination))
            XCTAssertEqual(values, original)
        }
        var empty: [Int] = []
        XCTAssertFalse(ListOrdering.move(&empty, fromOffsets: IndexSet(integer: 0), toOffset: 0))
    }

    func testEverySingleRowAndInsertionBoundaryMatchesRemoveThenInsert() {
        for count in 1...10 {
            for source in 0..<count {
                for destination in 0...count {
                    var values = Array(0..<count), expected = values
                    let moved = expected.remove(at: source)
                    expected.insert(moved, at: destination > source ? destination - 1 : destination)
                    ListOrdering.move(&values, fromOffsets: IndexSet(integer: source), toOffset: destination)
                    XCTAssertEqual(values, expected, "count=\(count) source=\(source) destination=\(destination)")
                }
            }
        }
    }

    func testSupplierOrderSurvivesEncodingWithoutChangingIdentityOrModels() throws {
        var profiles = APIProfile.presets
        let original = profiles
        let identities = Dictionary(uniqueKeysWithValues: original.map { ($0.id, $0) })
        XCTAssertTrue(ListOrdering.move(&profiles, fromOffsets: IndexSet([0, 2]), toOffset: 4))
        let restored = try JSONDecoder().decode([APIProfile].self, from: JSONEncoder().encode(profiles))
        XCTAssertEqual(restored.map(\.id), [original[1].id, original[3].id, original[0].id, original[2].id])
        for profile in restored { XCTAssertEqual(profile, identities[profile.id]) }
    }

    func testModelOrderPreservesSelectionParametersAndIndependentDraft() throws {
        var profile = APIProfile(name: "Relay", provider: .openAI, model: "first")
        let imageID = try profile.addModel("image-model")
        var image = try XCTUnwrap(profile.models.first { $0.id == imageID })
        image.displayName = "My image model"; image.modelType = .imageGeneration
        image.imageGenerationSettings = ImageGenerationSettings()
        image.imageGenerationSettings?.transparentBackground = true
        try profile.updateModel(image)
        let selectedID = try profile.addModel("gpt-6.1-sol")
        profile.selectModel(selectedID); profile.reasoningLevel = .high
        profile.systemPrompt = "Preserve me"; profile.maxOutputTokens = 8192
        let original = profile
        XCTAssertTrue(profile.moveModels(fromOffsets: IndexSet([0, 2]), toOffset: 3))
        let restored = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored.models.map(\.id), [imageID, original.models[0].id, selectedID])
        XCTAssertEqual(restored.selectedModelID, selectedID)
        XCTAssertEqual(restored.selectedModel, original.selectedModel)
        XCTAssertEqual(restored.models[0], image)
        XCTAssertEqual(original.models.map(\.model), ["first", "image-model", "gpt-6.1-sol"])
        let request = try RequestBuilder.chat(profile: restored, key: "test-key", messages: [ChatMessage(role: .user, content: "hello")])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6.1-sol")
        XCTAssertEqual(body["reasoning_effort"] as? String, "high")
    }

    func testReasoningStopsAndRequestsFollowModelIDsAfterReorderingSuppliersAndModels() throws {
        let cases: [(model: String, stops: [ReasoningLevel], level: ReasoningLevel, effort: String)] = [
            ("gpt-6.1-sol", [.low, .medium, .high, .xhigh, .max], .max, "max"),
            ("deepseek-flash", [.off, .low, .high, .max], .off, "none"),
            ("claude-opus-5-5", [.low, .medium, .high, .xhigh, .max], .xhigh, "xhigh"),
            ("gemini-3-flash", [.low, .medium, .high], .high, "high")
        ]
        var relay = APIProfile(name: "Relay", provider: .openAI, model: cases[0].model)
        var modelIDs = [relay.selectedModelID]
        for item in cases.dropFirst() { modelIDs.append(try relay.addModel(item.model)) }
        for (id, item) in zip(modelIDs, cases) {
            XCTAssertTrue(relay.selectModel(id))
            relay.reasoningLevel = item.level
        }
        let selectedSupplierID = relay.id
        var profiles = [APIProfile(name: "Other", provider: .openAI), relay]
        XCTAssertTrue(ListOrdering.move(&profiles, fromOffsets: IndexSet(integer: 1), toOffset: 0))
        XCTAssertTrue(profiles[0].moveModels(fromOffsets: IndexSet([0, 2]), toOffset: 4))
        let restored = try JSONDecoder().decode([APIProfile].self, from: JSONEncoder().encode(profiles))
        var selected = try XCTUnwrap(restored.first { $0.id == selectedSupplierID })
        XCTAssertEqual(selected.selectedModelID, modelIDs[3])
        // Revisit models with 5, 4 and 3 stops in a different order after persistence.
        for index in [1, 0, 3, 2, 1] {
            let item = cases[index]
            XCTAssertTrue(selected.selectModel(modelIDs[index]))
            XCTAssertEqual(selected.availableReasoningLevels, item.stops)
            XCTAssertEqual(selected.sliderReasoningLevel, item.level)
            let request = try RequestBuilder.chat(profile: selected, key: "test-key",
                messages: [ChatMessage(role: .user, content: "hello")])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, item.model)
            XCTAssertEqual(json["reasoning_effort"] as? String, item.effort)
        }
    }

    func testSearchOrderPreservesConnectionIdentityAndCustomJSONFields() throws {
        var custom = SearchProvider(kind: .custom)
        custom.endpoint = "https://search.example.com/custom"; custom.resultsPath = "data.items"
        var providers = [SearchProvider(kind: .deepSeek), SearchProvider(kind: .brave), custom]
        let original = providers
        XCTAssertTrue(ListOrdering.move(&providers, fromOffsets: IndexSet(integer: 2), toOffset: 0))
        let restored = try JSONDecoder().decode([SearchProvider].self, from: JSONEncoder().encode(providers))
        XCTAssertEqual(restored.map(\.id), [custom.id, original[0].id, original[1].id])
        XCTAssertEqual(restored[0], custom)
        let request = try WebSearch.request(provider: restored[0], key: "test-key", query: "search")
        XCTAssertEqual(request.url?.absoluteString, custom.endpoint)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(restored[0].resultsPath, "data.items")
    }
}
