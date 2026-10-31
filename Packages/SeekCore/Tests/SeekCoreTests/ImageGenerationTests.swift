import XCTest
@testable import SeekCore

final class ImageGenerationTests: XCTestCase {
    private func profile(_ provider: APIProvider = .openAI) throws -> APIProfile {
        var p = APIProfile(name: "Images", provider: provider, model: "image-test")
        var model = p.selectedModel; model.modelType = .imageGeneration
        try p.updateModel(model)
        return p
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as! [String: Any]
    }
    func testLegacyModelsDefaultToChatAndImageSettingsRoundTrip() throws {
        let old = try JSONDecoder().decode(APIModel.self, from: Data(#"{"id":"39093DCB-E39C-4F1F-91D5-F05EA51C8FC1","model":"old","systemPrompt":"","temperature":0.7,"sendsTemperature":false,"maxOutputTokens":4096}"#.utf8))
        XCTAssertEqual(old.effectiveType, .chat)
        var p = try profile(); var settings = p.imageSettings
        settings.resolution = .fourK; settings.format = .webp; settings.compression = 60; p.imageSettings = settings
        let restored = try JSONDecoder().decode(APIProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(restored, p); XCTAssertEqual(restored.imageSettings, settings)
        let next = try p.addModel("chat-test"); p.selectModel(next)
        XCTAssertEqual(p.selectedModel.effectiveType, .chat); XCTAssertEqual(p.imageSettings, ImageGenerationSettings())
    }
    func testOpenAIImageRequestIncludesAllOptionsAndNoChatFields() throws {
        var p = try profile(); var s = p.imageSettings
        s.resolution = .twoK; s.aspectRatio = "16:9"; s.quality = .high; s.moderation = .low
        s.transparentBackground = true; p.imageSettings = s
        p.baseURL = "https://example.com/v1/images/generations"
        let request = try ImageGenerationAPI.request(profile: p, key: "secret", prompt: "Create a scene")
        let json = try body(request)
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/v1/images/generations")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(json["quality"] as? String, "high"); XCTAssertEqual(json["moderation"] as? String, "low")
        XCTAssertEqual(json["background"] as? String, "transparent"); XCTAssertEqual(json["output_format"] as? String, "png")
        XCTAssertEqual(json["size"] as? String, try s.openAISize())
        for key in ["messages", "stream", "tools", "reasoning_effort", "max_tokens", "output_compression"] { XCTAssertNil(json[key]) }
    }
    func testFormatSwitchAndCompressionEndpoints() throws {
        var p = try profile(); var s = p.imageSettings; s.transparentBackground = true
        for format in [ImageGenerationSettings.Format.jpeg, .webp] {
            s.format = format
            for amount in [0, 30, 100] {
                s.compression = amount; p.imageSettings = s
                let json = try body(ImageGenerationAPI.request(profile: p, key: "k", prompt: "x"))
                XCTAssertEqual(json["output_compression"] as? Int, 100 - amount)
                XCTAssertEqual(json["background"] as? String, "opaque")
            }
        }
        s.compression = nil; p.imageSettings = s
        XCTAssertNil(try body(ImageGenerationAPI.request(profile: p, key: "k", prompt: "x"))["output_compression"])
        s.format = .png; s.compression = 50; p.imageSettings = s
        XCTAssertNil(try body(ImageGenerationAPI.request(profile: p, key: "k", prompt: "x"))["output_compression"])
    }
    func testResolutionBudgetsAndCustomRatios() throws {
        var s = ImageGenerationSettings()
        for resolution in ImageGenerationSettings.Resolution.allCases {
            for ratio in ImageGenerationSettings.ratios {
                s.resolution = resolution; s.aspectRatio = ratio
                let size = try s.openAISize().split(separator: "x").compactMap { Int($0) }
                XCTAssertEqual(size.count, 2); XCTAssertEqual(size[0] % 16, 0); XCTAssertEqual(size[1] % 16, 0)
                XCTAssertLessThanOrEqual(max(size[0],size[1]),3840)
                XCTAssertTrue((655_360...8_294_400).contains(size[0]*size[1]))
                let r = ratio.split(separator: ":").compactMap { Double($0) }
                XCTAssertLessThan(abs(Double(size[0])/Double(size[1]) - r[0]/r[1]),0.05)
            }
        }
        s.aspectRatio = "custom"; s.customRatio = "32：18"
        XCTAssertEqual(try s.normalizedRatio().title,"16:9")
        for bad in ["", "0:1", "NaN:1", "1:0", "100:1", "1:2:3"] {
            s.customRatio = bad; XCTAssertThrowsError(try s.normalizedRatio())
        }
    }
    func testGeminiNativeParametersAndPreferences() throws {
        var p = try profile(.gemini); var s = p.imageSettings
        s.resolution = .fourK; s.aspectRatio = "21:9"; s.quality = .high; s.format = .webp; s.compression = 25; s.moderation = .low
        p.imageSettings = s
        let request = try ImageGenerationAPI.request(profile: p, key: "gem-key", prompt: "test")
        XCTAssertTrue(request.url!.path.hasSuffix("/models/image-test:generateContent"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "gem-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let json = try body(request), config = json["generationConfig"] as! [String: Any]
        XCTAssertEqual((config["imageConfig"] as? [String:String])?["imageSize"], "4K")
        XCTAssertEqual((config["imageConfig"] as? [String:String])?["aspectRatio"], "21:9")
        XCTAssertEqual((json["safetySettings"] as? [[String:String]])?.count,4)
        let content = json["contents"] as! [[String:Any]], parts = content[0]["parts"] as! [[String:String]]
        XCTAssertTrue(parts[0]["text"]!.contains("quality: high")); XCTAssertTrue(parts[0]["text"]!.contains("compression amount: 25%"))
        XCTAssertNil(config["output_format"]); XCTAssertNil(config["quality"])
    }
    func testInvalidParametersDoNotMakeAnImageRequest() throws {
        var p = try profile(); var s = p.imageSettings; s.compression = 101; p.imageSettings = s
        XCTAssertThrowsError(try ImageGenerationAPI.request(profile: p,key:"k",prompt:"x"))
        p.imageSettings = ImageGenerationSettings()
        XCTAssertThrowsError(try ImageGenerationAPI.request(profile:p,key:"",prompt:"x"))
        XCTAssertThrowsError(try ImageGenerationAPI.request(profile:p,key:"k",prompt:" "))
        XCTAssertThrowsError(try ImageGenerationAPI.request(profile:try profile(.claude),key:"k",prompt:"x"))
    }
    func testOpenAIBase64URLAndUsageResponses() throws {
        let payload: [String:Any] = ["data":[["b64_json":Data([1,2,3]).base64EncodedString()]],
            "usage":["input_tokens":10,"output_tokens":20,"total_tokens":30]]
        let result = try ImageGenerationAPI.decode(JSONSerialization.data(withJSONObject:payload),provider:.openAI,format:.png)
        XCTAssertEqual(result.images[0].data,Data([1,2,3])); XCTAssertEqual(result.usage?.totalTokens,30)
        let remote = try ImageGenerationAPI.decode(Data(#"{"data":[{"url":"https://cdn.example.com/result.png?signed=abc"}]}"#.utf8),provider:.openAI,format:.png)
        XCTAssertEqual(remote.images[0].url?.host,"cdn.example.com")
        for url in ["http://example.com/x", "file:///x", "https://key@example.com/x"] {
            XCTAssertThrowsError(try ImageGenerationAPI.decode(JSONSerialization.data(withJSONObject:["data":[["url":url]]]),provider:.openAI,format:.png))
        }
    }
    func testGeminiImageTextUsageAndBlockedOutput() throws {
        let root: [String:Any] = ["candidates":[["content":["parts":[
            ["thought":true,"text":"private"], ["text":"Here is your image"],
            ["inlineData":["mimeType":"image/png","data":Data([1,2,3]).base64EncodedString()]]]]]],
            "usageMetadata":["promptTokenCount":4,"candidatesTokenCount":12,"totalTokenCount":16]]
        let result = try ImageGenerationAPI.decode(JSONSerialization.data(withJSONObject:root),provider:.gemini,format:.png)
        XCTAssertEqual(result.images.count,1); XCTAssertEqual(result.text,"Here is your image"); XCTAssertEqual(result.usage?.totalTokens,16)
        for raw in [#"{"promptFeedback":{"blockReason":"SAFETY"}}"#, #"{"candidates":[]}"#, #"{"data":[{"b64_json":"!bad!"}]}"#] {
            XCTAssertThrowsError(try ImageGenerationAPI.decode(Data(raw.utf8),provider:raw.contains("data") ? .openAI : .gemini,format:.png))
        }
    }
    func testImageReplySnapshotAndConversationRestore() throws {
        var p = try profile(); let imageID = p.selectedModelID
        var settings = p.imageSettings; settings.quality = .high; settings.format = .webp; p.imageSettings = settings
        var reply = ChatMessage(role:.assistant, content:"Generated", model:p.model)
        reply.imageGenerationSettings = settings
        reply.attachments = [ChatAttachment(name:"output.webp",mimeType:"image/webp",kind:.image,byteCount:100)]
        let chat = Conversation(profileID:p.id,messages:[reply],modelID:imageID)
        let restored = try JSONDecoder().decode(Conversation.self,from:JSONEncoder().encode(chat))
        XCTAssertEqual(restored,chat)
        let chatID = try p.addModel("chat-model"); p.selectModel(chatID)
        XCTAssertEqual(p.selectedModel.effectiveType,.chat)
        XCTAssertTrue(p.restoreModel(for:restored)); XCTAssertEqual(p.selectedModel.effectiveType,.imageGeneration)
        XCTAssertEqual(p.imageSettings,settings)
    }
    func testGeneratedOutputIsNotImplicitlyUploadedWhenSwitchingToChat() throws {
        let p = APIProfile(name:"Chat",provider:.openAI,model:"chat-test")
        var generated = ChatMessage(role:.assistant,content:"Generated image")
        generated.imageGenerationSettings = ImageGenerationSettings()
        generated.attachments = [ChatAttachment(name:"output.png",mimeType:"image/png",kind:.image,byteCount:100)]
        let request = try RequestBuilder.chat(profile:p,key:"k",messages:[ChatMessage(role:.user,content:"draw"),
            generated,ChatMessage(role:.user,content:"describe the process")])
        let json = try body(request), messages = json["messages"] as! [[String:Any]]
        XCTAssertEqual(messages[1]["content"] as? String,"Generated image")
        for key in ["quality","output_format","moderation","background","imageGenerationSettings"] { XCTAssertNil(json[key]) }
    }
}

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
