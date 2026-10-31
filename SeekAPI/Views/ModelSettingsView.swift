import SwiftUI
import SeekCore

@MainActor
struct ModelSettingsView: View {
    @Binding var profile: APIProfile
    @Environment(\.dismiss) private var dismiss
    @State private var model: APIModel
    @State private var makeDefault: Bool
    @State private var errorText: String?
    @State private var importingIcon = false

    init(profile: Binding<APIProfile>, initialModel: APIModel) {
        _profile = profile
        _model = State(initialValue: initialModel)
        _makeDefault = State(initialValue: profile.wrappedValue.selectedModelID == initialModel.id)
    }

    var body: some View {
        SettingsScaffold(title: "模型设置", onSave: save, saveDisabled: importingIcon) {
            Form {
                Section {
                    Picker("模型类型", selection: Binding(get: { model.effectiveType }, set: { model.modelType = $0 })) {
                        ForEach(ModelType.allCases) { Text($0.title).tag($0) }
                    }
                    .accessibilityIdentifier("settings.model.type")
                    LabeledContent("模型名称") {
                        TextField("API 模型 ID", text: $model.model)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .font(.system(size: 13, design: .monospaced))
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("模型名称，API 模型 ID")
                            .accessibilityIdentifier("settings.model")
                    }
                    LabeledContent("显示名称") {
                        TextField("留空使用模型名称", text: Binding(get: { model.displayName ?? "" }, set: { model.displayName = $0 }))
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("显示名称")
                            .accessibilityIdentifier("settings.model.displayName")
                    }
                    Button { makeDefault = true } label: {
                        Label(makeDefault ? "默认模型" : "设为默认模型",
                              systemImage: makeDefault ? "checkmark.circle.fill" : "circle")
                    }
                    .disabled(makeDefault)
                } header: { Text("模型") } footer: {
                    Text("模型名称用于 API 请求；显示名称用于聊天和列表，可留空。")
                }
                ModelIconSettings(model: $model, provider: profile.provider, importing: $importingIcon)
                if model.effectiveType == .imageGeneration {
                    Section {
                        ImageParametersContent(settings: Binding(get: { model.imageGenerationSettings ?? ImageGenerationSettings() },
                            set: { model.imageGenerationSettings = $0 }), provider: profile.provider)
                    } header: { Text("生图默认参数") }
                } else {
                Section {
                    TextField("系统提示词（可选）", text: $model.systemPrompt, axis: .vertical).lineLimit(3...8)
                    Stepper("最大输出：\(model.maxOutputTokens) tokens", value: $model.maxOutputTokens, in: 256...131072, step: 256)
                        .font(.system(size: 13))
                    SeekSwitch("发送 Temperature 参数", isOn: $model.sendsTemperature)
                    if model.sendsTemperature {
                        HStack {
                            Text("温度 \(model.temperature, specifier: "%.1f")").font(.system(size: 13))
                            Slider(value: $model.temperature, in: 0...1, step: 0.1).accessibilityLabel("温度")
                        }
                    }
                } header: { Text("对话偏好") } footer: { Text("这些参数和聊天中的推理等级分别保存在每个模型下。") }
                }
                if let errorText {
                    Section { Text(errorText).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                }
            }
        }
    }

    private func save() {
        do {
            var candidate = profile
            let previous = candidate.selectedModelID
            try candidate.updateModel(model)
            candidate.selectModel(model.id)
            try RequestBuilder.validate(candidate)
            if model.effectiveType == .imageGeneration { try candidate.imageSettings.validate(provider: candidate.provider) }
            if !makeDefault { candidate.selectModel(previous) }
            profile = candidate
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
