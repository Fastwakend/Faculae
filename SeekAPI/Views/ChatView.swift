import SwiftUI
import SeekCore

@MainActor
struct ChatView: View {
    let store: AppStore
    let topSafeArea: CGFloat
    let bottomSafeArea: CGFloat
    let showsHistoryButton: Bool
    let onHistory: () -> Void
    let onSettings: () -> Void
    let onPresentationChange: (Bool) -> Void
    @State private var draft = ""
    @State private var followsStream = true
    private var attachments: [ChatAttachment] {
        get { store.draftAttachments }
        nonmutating set { store.draftAttachments = newValue }
    }
    @State private var showsAttachments = false
    @State private var showsReasoning = false
    @State private var showsImageParameters = false
    @State private var scrollContext = TranscriptScrollContext()
    @State private var scrollRequest = 0
    @State private var composerHeight: CGFloat = 128
    @FocusState private var composerFocused: Bool
    @Environment(\.chatTextScale) private var textScale
    @ScaledMetric(relativeTo: .body) private var inputSize: CGFloat = 17
    @ScaledMetric(relativeTo: .title2) private var greetingSize: CGFloat = 21
    @ScaledMetric(relativeTo: .subheadline) private var actionLabelSize: CGFloat = 13

    private var messages: [ChatMessage] { store.currentConversation?.messages ?? [] }
    private var isImageGeneration: Bool { store.selectedProfile.selectedModel.effectiveType == .imageGeneration }
    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack(alignment: .top) {
                Group {
                    if messages.isEmpty { welcome }
                    else { transcript }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                NativeScrollHeader(scrollContext: scrollContext) {
                    header.padding(.top, topSafeArea)
                        .background {
                            if #unavailable(iOS 26) {
                                Rectangle().fill(.regularMaterial).allowsHitTesting(false)
                            }
                        }
                }
                .frame(height: topSafeArea + 62)
                .zIndex(1)
            }
            composer
                .padding(.bottom, bottomSafeArea)
        }
        .background(Color(uiColor: .systemBackground))
        .accessibilityHidden(isReasoningExpansionPresented)
        .overlayPreferenceValue(ChatControlAnchorsKey.self) { anchors in
            if #available(iOS 26, *), isImageGeneration, let source = anchors.imageParameters, let controls = anchors.controls {
                GeometryReader { geometry in
                    ImageParametersExpansion(store: store, isPresented: $showsImageParameters,
                        sourceBounds: geometry[source], controlsBounds: geometry[controls],
                        viewport: geometry.size, topSafeArea: topSafeArea,
                        source: imageParametersLabel, onOpen: { composerFocused = false })
                }.transition(.identity)
            } else if #available(iOS 26, *), let source = anchors.reasoning, let controls = anchors.controls {
                GeometryReader { geometry in
                    ReasoningExpansion(store: store, isPresented: $showsReasoning,
                        sourceBounds: geometry[source], controlsBounds: geometry[controls],
                        viewport: geometry.size, topSafeArea: topSafeArea,
                        source: reasoningLabel, onOpen: { composerFocused = false })
                }
                .transition(.identity)
            }
        }
        .sheet(isPresented: $showsAttachments) {
            AttachmentPanel(attachments: Binding(get: { attachments }, set: { attachments = $0 }))
        }
        .onChange(of: store.selectedProfileID) { _, _ in dismissReasoning() }
        .onChange(of: showsReasoning) { _, _ in onPresentationChange(showsReasoning || showsImageParameters || showsAttachments) }
        .onChange(of: showsImageParameters) { _, _ in onPresentationChange(showsReasoning || showsImageParameters || showsAttachments) }
        .onChange(of: showsAttachments) { _, _ in onPresentationChange(showsReasoning || showsImageParameters || showsAttachments) }
        .onChange(of: store.selectedProfile.selectedModelID) { _, _ in dismissReasoning() }
        .onChange(of: store.isStreaming) { _, streaming in
            if streaming { dismissReasoning() }
        }
        .onChange(of: store.selectedConversationID) { old, new in
            // Sending the first message creates an ID after draft ownership transfers to history.
            if old != new {
                dismissReasoning()
                followsStream = true
                if !attachments.isEmpty { clearAttachments() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if showsHistoryButton {
                Button {
                    composerFocused = false
                    onHistory()
                } label: {
                    HistoryGlyph().frame(width: 22, height: 20)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .seekGlass(in: Circle())
                }
                .buttonStyle(QuietGlassPressStyle())
                .foregroundStyle(.primary)
                .accessibilityLabel("历史对话")
                .accessibilityIdentifier("chat.history")
            }
            Spacer(minLength: 0)
            if !messages.isEmpty {
                Text(store.currentConversation?.title ?? "新对话")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            Button(action: newConversation) {
                NewConversationGlyph().frame(width: 24, height: 24)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
                    .seekGlass(in: Circle())
            }
            .foregroundStyle(.primary)
            .buttonStyle(QuietGlassPressStyle())
            .accessibilityLabel("新建对话")
            .accessibilityIdentifier("chat.new")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)

    }

    @ViewBuilder
    private var profileActions: some View {
        ForEach(store.profiles) { profile in
            Menu {
                ForEach(profile.models) { model in
                    Button { Haptics.shared.play(.listItem); store.selectModel(profileID: profile.id, modelID: model.id) } label: {
                        MenuSelectionLabel(title: model.displayTitle,
                                           isSelected: profile.id == store.selectedProfileID && model.id == profile.selectedModelID)
                    }
                    .disabled(store.isStreaming)
                }
            } label: {
                MenuSelectionLabel(title: profile.name, isSelected: profile.id == store.selectedProfileID)
            }
            .disabled(store.isStreaming)
        }
        Divider()
        Button("API 与模型设置", systemImage: "slider.horizontal.3", action: onSettings)
    }

    private var welcome: some View {
        VStack(spacing: 26) {
            ModelLogo(model: store.selectedProfile.selectedModel, provider: store.selectedProfile.provider, size: 54)
            Text(isImageGeneration ? "描述画面，让灵感成为图像" : "你好，我能帮什么忙吗？")
                .font(.system(size: greetingSize, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.horizontal, 24)
        .padding(.top, topSafeArea + 62)
        .padding(.bottom, composerHeight + bottomSafeArea)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("chat.welcome")
    }

    private var transcript: some View {
        ChatTranscriptView(messages: messages, conversationID: store.selectedConversationID,
                           isStreaming: store.isStreaming, topInset: topSafeArea + 62,
                           bottomInset: composerHeight + bottomSafeArea + 12,
                           scrollContext: scrollContext, scrollRequest: scrollRequest,
                           followsStream: $followsStream, onRegenerate: store.regenerate,
                           onBranch: store.branchConversation)
            .overlay(alignment: .bottomTrailing) {
                if !followsStream {
                    CircleIconButton(symbol: "arrow.down", label: "回到最新消息") {
                        followsStream = true
                        scrollRequest += 1
                    }
                    .padding(16)
                    .padding(.bottom, composerHeight + bottomSafeArea)
                }
            }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: attachments) { attachment in
                    attachments.removeAll { $0.id == attachment.id }
                    Task { await AttachmentStore.shared.remove([attachment]) }
                }
            }
            TextField(isImageGeneration ? "描述你想生成的图像" : "发送消息", text: $draft, axis: .vertical)
                .font(.system(size: inputSize * textScale))
                .lineLimit(1...6)
                .focused($composerFocused)
                .frame(minHeight: 32, alignment: .topLeading)
                .padding(.horizontal, 3)
                .accessibilityLabel("发送消息")
                .accessibilityIdentifier("chat.composer")
            composerActions
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .seekGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .transformAnchorPreference(key: ChatControlAnchorsKey.self, value: .bounds) { anchors, bounds in
            // Preserve the descendant button anchor when adding the composer.
            anchors.composer = bounds
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 0)
        .frame(maxWidth: 780)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            if abs(composerHeight - height) > 0.5 { composerHeight = height }
        }
    }

    private var composerActions: some View {
        HStack(alignment: .center, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                SeekGlassGroup(spacing: 0) {
                    HStack(spacing: 6) {
                        modelSelector
                        if isImageGeneration { imageParametersButton }
                        else { reasoningButton; searchSelector }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 1)
            }
            .scrollDisabled(showsReasoning || showsImageParameters)
            .frame(height: max(44, actionLabelSize * 1.6 + 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .transformAnchorPreference(key: ChatControlAnchorsKey.self, value: .bounds) { anchors, bounds in
                anchors.controls = bounds
            }
            utilityActions.fixedSize()
        }
        .accessibilityIdentifier("chat.composer.bottomBar")
    }

    private var modelSelector: some View {
        Menu { profileActions } label: {
            Label {
                Text(store.selectedProfile.selectedModel.displayTitle)
            } icon: {
                ModelLogo(model: store.selectedProfile.selectedModel, provider: store.selectedProfile.provider,
                          size: max(16, actionLabelSize * 1.2))
                    .accessibilityHidden(true)
            }
            .font(.system(size: actionLabelSize, weight: .medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(uiColor: .label))
            .frame(minHeight: 24)
        }
        .seekNativeGlassButton()
        .controlSize(.small)
        .tint(Color.primary)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("API 服务：\(store.selectedProfile.name)，模型：\(store.selectedProfile.selectedModel.displayTitle)")
        .accessibilityIdentifier("chat.modelSelector")
    }

    private var searchSelector: some View {
        Menu {
            Button(store.searchEnabled ? "关闭联网搜索" : "开启联网搜索", systemImage: store.searchEnabled ? "globe.badge.chevron.backward" : "globe") {
                if store.selectedSearchProvider == nil { onSettings() }
                else { store.searchEnabled.toggle() }
            }
            ForEach(store.searchProviders) { provider in
                Button {
                    store.selectSearchProvider(provider.id); store.searchEnabled = true
                } label: {
                    MenuSelectionLabel(title: provider.name, isSelected: store.searchEnabled && provider.id == store.selectedSearchProviderID)
                }
            }
            Divider()
            Button("搜索服务设置", systemImage: "gearshape", action: onSettings)
        } label: {
            Image(systemName: "globe").font(.system(size: actionLabelSize, weight: .medium))
                .foregroundStyle(store.searchEnabled ? SeekTheme.blue : Color(uiColor: .label))
                .frame(minWidth: 20, minHeight: 24)
        }
        .seekNativeGlassButton().controlSize(.small).tint(Color.primary)
        .accessibilityLabel(store.searchEnabled ? "联网搜索已开启，" + (store.selectedSearchProvider?.name ?? "") : "联网搜索已关闭")
        .disabled(store.isStreaming)
    }

    private var imageParametersLabel: some View {
        Text("参数").font(.system(size: actionLabelSize, weight: .medium))
            .lineLimit(1).fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(Color(uiColor: .label)).frame(minHeight: 24)
    }

    @ViewBuilder
    private var imageParametersButton: some View {
        if #available(iOS 26, *) {
            imageParametersLabel.padding(.horizontal, 12).padding(.vertical, 4)
                .anchorPreference(key: ChatControlAnchorsKey.self, value: .bounds) { .init(imageParameters: $0) }
                .hidden().accessibilityHidden(true)
        } else {
            Button { composerFocused = false; showsImageParameters = true } label: { imageParametersLabel }
                .seekNativeGlassButton().controlSize(.small).disabled(store.isStreaming)
                .popover(isPresented: $showsImageParameters, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    ScrollView {
                        ImageParametersContent(settings: Binding(get: { store.selectedProfile.imageSettings },
                            set: { store.setImageSettings($0) }), provider: store.selectedProfile.provider)
                    }.frame(width: 340, height: 500).presentationCompactAdaptation(.popover)
                }
        }
    }

    @ViewBuilder
    private var reasoningButton: some View {
        if #available(iOS 26, *) {
            // Reserve only layout space here. The persistent overlay owns the
            // single visible glass button throughout opening and closing.
            reasoningLabel
                .padding(.horizontal, 12).padding(.vertical, 4)
                .anchorPreference(key: ChatControlAnchorsKey.self, value: .bounds) { .init(reasoning: $0) }
                .hidden()
                .accessibilityHidden(true)
        } else {
            reasoningTrigger
                .popover(isPresented: $showsReasoning, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                    ReasoningSettings(store: store)
                        .frame(width: 316)
                        .presentationCompactAdaptation(.popover)
                }
        }
    }

    private var reasoningTrigger: some View {
        Button {
            composerFocused = false
            showsReasoning = true
        } label: { reasoningLabel }
        .seekNativeGlassButton()
        .controlSize(.small)
        .tint(Color.primary)
        .accessibilityLabel("调整推理等级")
        .accessibilityValue(reasoningTitle)
        .accessibilityIdentifier("chat.reasoning")
        .disabled(store.isStreaming)
    }

    private var reasoningLabel: some View {
        Text(reasoningTitle)
        .font(.system(size: actionLabelSize, weight: .medium))
        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        .foregroundStyle(Color(uiColor: .label))
        .frame(minHeight: 24)
    }

    private var isReasoningExpansionPresented: Bool {
        if #available(iOS 26, *) { return showsReasoning || showsImageParameters }
        return false
    }

    private func dismissReasoning() { showsReasoning = false; showsImageParameters = false }

    private var utilityActions: some View {
        HStack(spacing: 2) {
            Button { composerFocused = false; showsAttachments = true } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 27, weight: .regular))
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(width: 44, height: 44)
            }
            .disabled(store.isStreaming)
            .accessibilityLabel("添加照片或文件")
            .accessibilityIdentifier("chat.attachments")
            Button {
                if store.isStreaming { store.stopGeneration() }
                else if store.send(draft, attachments: attachments) {
                    followsStream = true; scrollRequest += 1
                    draft = ""; attachments = []; composerFocused = false
                }
            } label: {
                Image(systemName: store.isStreaming ? "stop.circle.fill" : (canSend ? "arrow.up.circle.fill" : "arrow.up.circle"))
                    .font(.system(size: 29, weight: .regular))
                    .foregroundStyle(store.isStreaming || canSend ? SeekTheme.blue : Color.secondary)
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled(!store.isStreaming && !canSend)
            .accessibilityLabel(store.isStreaming ? "停止生成" : "发送消息")
            .accessibilityIdentifier("chat.send")
        }
        .buttonStyle(.plain)
    }

    private var reasoningTitle: String {
        store.selectedProfile.explicitReasoningLevel?.title ?? ReasoningLevel.automatic.title
    }

    private func clearAttachments() {
        let discarded = attachments
        attachments = []
        Task { await AttachmentStore.shared.remove(discarded) }
    }

    private func newConversation() {
        dismissReasoning()
        clearAttachments()
        store.newConversation()
        draft = ""
        composerFocused = false
    }
}
