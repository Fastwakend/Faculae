import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import SeekCore

final class ReasoningTests: XCTestCase {
    private func body(_ profile: APIProfile) throws -> [String: Any] {
        let request = try RequestBuilder.chat(profile: profile, key: "test-not-secret", messages: [ChatMessage(role: .user, content: "hello")])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }

    func testExactRequestedFamilyStops() {
        XCTAssertEqual(ModelFamily.openAI.reasoningLevels.map(\.title), ["Low", "Medium", "High", "Xhigh", "Max"])
        XCTAssertEqual(ModelFamily.claude.reasoningLevels.map(\.title), ["Low", "Medium", "High", "Xhigh", "Max"])
        XCTAssertEqual(ModelFamily.deepSeek.reasoningLevels.map(\.title), ["Off", "Low", "High", "Max"])
        XCTAssertEqual(ModelFamily.gemini.reasoningLevels.map(\.title), ["Low", "Medium", "High"])
        for family in [ModelFamily.openAI, .claude, .deepSeek, .gemini] {
            XCTAssertFalse(family.reasoningLevels.contains(.automatic))
        }
    }

    func testFamilyUsesModelBeforeProtocolOrDisplayName() {
        XCTAssertEqual(APIProfile(name: "Anything", provider: .openAI, model: "org/claude-opus-5-5").modelFamily, .claude)
        XCTAssertEqual(APIProfile(name: "Claude", provider: .openAI, model: "deepseek-v4-pro").modelFamily, .deepSeek)
        XCTAssertEqual(APIProfile(name: "Other", provider: .openAI, model: "models/gemini-3-flash").modelFamily, .gemini)
        XCTAssertEqual(APIProfile(name: "Relay", provider: .openAI, model: "gpt-6.1-sol").modelFamily, .openAI)
    }

    func testOpenAIEachEffortIsPassedWithoutDowngrade() throws {
        for level in ModelFamily.openAI.reasoningLevels {
            let profile = APIProfile(name: "o", provider: .openAI, model: "gpt-6.1-sol", reasoningLevel: level)
            let json = try body(profile)
            XCTAssertEqual(json["reasoning_effort"] as? String, level.rawValue)
            XCTAssertNotNil(json["max_completion_tokens"])
        }
    }

    func testDeepSeekOffLowHighMaxPayloadsAndTemperature() throws {
        for model in ["deepseek-flash", "deepseek-v4-pro", "deepseek-chat", "deepseek-reasoner"] {
            for level in ModelFamily.deepSeek.reasoningLevels {
                let profile = APIProfile(name: "d", provider: .openAI, baseURL: "https://api.deepseek.com", model: model, sendsTemperature: true, reasoningLevel: level)
                let json = try body(profile)
                XCTAssertEqual(json["model"] as? String, model) // Never silently replace the user's model.
                XCTAssertEqual(json["reasoning_effort"] as? String, level == .off ? "none" : level.rawValue)
                XCTAssertEqual((json["thinking"] as? [String: String])?["type"], level == .off ? "disabled" : "enabled")
                if level == .off { XCTAssertNotNil(json["temperature"]) }
                else { XCTAssertNil(json["temperature"]) }
            }
        }
    }

    func testNativeClaudeAllFiveEffortsIncludingNewerVersions() throws {
        for model in ["claude-opus-5-5", "claude-sonnet-5", "claude-opus-4-8", "claude-mythos-5-1"] {
            for level in ModelFamily.claude.reasoningLevels {
                let json = try body(APIProfile(name: "c", provider: .claude, model: model, reasoningLevel: level))
                XCTAssertEqual((json["output_config"] as? [String: String])?["effort"], level.rawValue)
                XCTAssertEqual((json["thinking"] as? [String: String])?["type"], "adaptive")
            }
        }
    }

    func testClaudeManualBudgetStopsRemainDistinctWithinOutputLimit() throws {
        var budgets: [Int] = []
        for level in ModelFamily.claude.reasoningLevels {
            let profile = APIProfile(name: "c", provider: .claude, model: "claude-sonnet-4-5", maxOutputTokens: 4096, reasoningLevel: level)
            let json = try body(profile)
            let thinking = try XCTUnwrap(json["thinking"] as? [String: Any])
            let budget = try XCTUnwrap(thinking["budget_tokens"] as? Int)
            XCTAssertGreaterThanOrEqual(budget, 1024)
            XCTAssertLessThan(budget, profile.maxOutputTokens)
            budgets.append(budget)
        }
        XCTAssertEqual(Set(budgets).count, 5)
        XCTAssertEqual(budgets, budgets.sorted())
        let original = APIProfile(name: "c", provider: .claude, model: "claude-sonnet-4-20250514")
        XCTAssertEqual(original.reasoningControl, .claudeBudget)
    }

    func testCompatibleClaudeForwardsAllFiveAndGeminiAllThree() throws {
        for (model, family) in [("claude-opus-5-5", ModelFamily.claude), ("gemini-3-flash", .gemini)] {
            for level in family.reasoningLevels {
                let json = try body(APIProfile(name: "Relay", provider: .openAI, model: model, reasoningLevel: level))
                XCTAssertEqual(json["reasoning_effort"] as? String, level.rawValue)
            }
        }
    }

    func testGeminiThreeLevelsAreNotCollapsed() throws {
        var budgets: [Int] = []
        for level in ModelFamily.gemini.reasoningLevels {
            for model in ["gemini-3-flash-preview", "gemini-3-pro-preview"] {
                let json = try body(APIProfile(name: "g", provider: .gemini, model: model, reasoningLevel: level))
                let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
                XCTAssertEqual((config["thinkingConfig"] as? [String: String])?["thinkingLevel"], level.rawValue.uppercased())
            }
            let json = try body(APIProfile(name: "g", provider: .gemini, model: "gemini-2.5-flash", reasoningLevel: level))
            let config = try XCTUnwrap(json["generationConfig"] as? [String: Any])
            budgets.append(try XCTUnwrap((config["thinkingConfig"] as? [String: Int])?["thinkingBudget"]))
        }
        XCTAssertEqual(budgets, [1024, 2048, 4095])
    }

    func testLegacyAutomaticDoesNotIntroduceUnrequestedOverrides() throws {
        for provider in APIProvider.allCases {
            let json = try body(APIProfile(name: "old", provider: provider, reasoningLevel: .automatic))
            XCTAssertNil(json["reasoning_effort"])
            XCTAssertNil(json["thinking"])
            XCTAssertNil(json["output_config"])
        }
        for level in ReasoningLevel.allCases {
            var profile = APIProfile(name: "saved", provider: .openAI, model: "claude-opus-5-5", reasoningLevel: level)
            let decoded = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(profile))
            XCTAssertEqual(decoded.reasoningLevel, level)
            profile.model = "gemini-3-flash"
            XCTAssertTrue(profile.availableReasoningLevels.contains(profile.sliderReasoningLevel))
        }
    }

    func testDeepSeekOverClaudeProtocolUsesNativeFields() throws {
        for level in ModelFamily.deepSeek.reasoningLevels {
            let profile = APIProfile(name: "d", provider: .claude, baseURL: "https://api.deepseek.com/anthropic", model: "deepseek-flash", reasoningLevel: level)
            let json = try body(profile)
            XCTAssertEqual((json["reasoning"] as? [String: String])?["effort"], level == .off ? "none" : level.rawValue)
            XCTAssertNil(json["reasoning_effort"])
        }
    }
}
