import SwiftUI
import SeekCore

@MainActor
struct HistoryView: View {
    let store: AppStore
    let onSelect: () -> Void
    let onSettings: () -> Void
    @State private var query = ""
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var confirmsBatchDelete = false
    @State private var renaming: Conversation?
    @State private var renameText = ""
    @State private var deleting: Conversation?
    @State private var exportFile: ChatExportFile?
    @State private var exportNotice: String?
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var filtered: [Conversation] {
        store.sortedConversations.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) ||
                $0.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedConversations: [Conversation] { store.conversations.filter { selection.contains($0.id) } }
    private var allSelectedPinned: Bool { !selection.isEmpty && selectedConversations.allSatisfy(\.isPinned) }

    private var sections: [HistorySection] {
        let calendar = Calendar.current
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let chats = filtered
        return [
            HistorySection(title: "置顶", chats: chats.filter(\.isPinned)),
            HistorySection(title: "今天", chats: chats.filter { !$0.isPinned && calendar.isDateInToday($0.updatedAt) }),
            HistorySection(title: "昨天", chats: chats.filter { !$0.isPinned && calendar.isDateInYesterday($0.updatedAt) }),
            HistorySection(title: "过去 7 天", chats: chats.filter {
                !$0.isPinned && !calendar.isDateInToday($0.updatedAt) &&
                !calendar.isDateInYesterday($0.updatedAt) && $0.updatedAt >= weekAgo
            }),
            HistorySection(title: "更早", chats: chats.filter { !$0.isPinned && $0.updatedAt < weekAgo })
        ].filter { !$0.chats.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            if selecting { selectionHeader } else { search }
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "还没有对话" : "没有搜索结果",
                    systemImage: query.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                    description: Text("你的对话保存在这台设备上"))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.chats) { conversation in row(conversation) }
                        } header: {
                            sectionHeader(section)
                        }
                        .listSectionSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
                .environment(\.defaultMinListRowHeight, 48)
            }
            if selecting { batchActions } else { footer }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $exportFile) { file in
            ChatFileExportPicker(file: file) { exportFile = nil }.onDisappear { file.remove() }
        }
        .alert("导出对话", isPresented: Binding(get: { exportNotice != nil }, set: { if !$0 { exportNotice = nil } })) {
            Button("知道了", role: .cancel) { exportNotice = nil }
        } message: { Text(exportNotice ?? "") }
        .accessibilityAction(.escape, onSelect)
        .onChange(of: store.conversations.map(\.id)) { _, ids in selection.formIntersection(Set(ids)) }
        .alert("重命名对话", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("对话标题", text: $renameText)
            Button("保存") { if let renaming { store.renameConversation(renaming.id, title: renameText) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("删除这个对话？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("删除对话", role: .destructive) { if let deleting { store.deleteConversation(deleting.id) }; deleting = nil }
        } message: { Text("此操作会删除设备上的这条聊天记录。") }
        .confirmationDialog("删除选中的 \(selection.count) 条对话？", isPresented: $confirmsBatchDelete, titleVisibility: .visible) {
            Button("删除所选对话", role: .destructive) {
                store.deleteConversations(selection)
                endSelection()
            }
            Button("取消", role: .cancel) {}
        } message: { Text("选中的聊天记录和不再使用的附件将从本机移除。此操作无法撤销。") }
    }

    private var search: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索对话内容…", text: $query)
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityLabel("搜索对话内容")
                .accessibilityIdentifier("history.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, 15)
        .frame(height: 44)
        .seekGlass(in: Capsule())
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .buttonStyle(QuietGlassPressStyle())
    }

    private var selectionHeader: some View {
        HStack {
            Text("选择对话").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            CircleIconButton(symbol: "xmark", label: "退出多选", action: endSelection)
        }
        .frame(height: 44)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func sectionHeader(_ section: HistorySection) -> some View {
        HStack {
            Text(section.title).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            if section.id == sections.first?.id && !selecting {
                Button {
                    searchFocused = false
                    selection = []
                    selecting = true
                } label: {
                    Image(systemName: "checklist")
                        .font(.system(size: 19))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(QuietGlassPressStyle())
                .accessibilityLabel("多选对话")
                .accessibilityIdentifier("history.multiSelect")
            }
        }
        .textCase(nil)
        .frame(minHeight: 44)
    }

    private func row(_ conversation: Conversation) -> some View {
        Button {
            Haptics.shared.play(.listItem)
            searchFocused = false
            if selecting {
                if selection.contains(conversation.id) { selection.remove(conversation.id) }
                else { selection.insert(conversation.id) }
            } else {
                store.selectConversation(conversation)
                onSelect()
            }
        } label: {
            HStack(spacing: selecting ? 12 : 7) {
                if selecting {
                    Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(selection.contains(conversation.id) ? SeekTheme.blue : Color(uiColor: .tertiaryLabel))
                        .accessibilityHidden(true)
                }
                Text(conversation.title).font(.body).lineLimit(1)
                Spacer(minLength: 0)
                if store.isGenerating(conversation.id) {
                    ProgressView().controlSize(.small).accessibilityLabel("正在生成回复")
                }
                if conversation.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(!selecting && conversation.id == store.selectedConversationID ? SeekTheme.blue.opacity(0.065) : .clear,
                in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 14))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityAddTraits((selecting ? selection.contains(conversation.id) : conversation.id == store.selectedConversationID) ? [.isSelected] : [])
        .accessibilityValue(selecting ? (selection.contains(conversation.id) ? "已选择" : "未选择") : "")
        .contextMenu {
            if !selecting {
                Button { store.togglePin(conversation.id) } label: {
                    Label { Text(conversation.isPinned ? "取消置顶" : "置顶") } icon: {
                        MenuArtwork.monochromeSymbol("pin", colorScheme: colorScheme)
                    }
                }
                Button { renameText = conversation.title; renaming = conversation } label: {
                    Label { Text("重命名") } icon: { MenuArtwork.monochromeSymbol("pencil", colorScheme: colorScheme) }
                }
                Button { exportConversation(conversation) } label: {
                    Label { Text("导出对话为MD文件") } icon: {
                        MenuArtwork.monochromeSymbol("square.and.arrow.up", colorScheme: colorScheme)
                    }
                }
                Button(role: .destructive) { deleting = conversation } label: {
                    Label { Text("删除对话") } icon: { MenuArtwork.monochromeSymbol("trash", colorScheme: colorScheme) }
                }
            }
        }

    }

    private var batchActions: some View {
        VStack(spacing: 2) {
            Text(selection.isEmpty ? "轻点对话以选择" : "已选择 \(selection.count) 条对话")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("history.selectionCount")
            HStack(spacing: 12) {
                Button {
                    store.setConversationsPinned(selection, pinned: !allSelectedPinned)
                } label: {
                    Label(allSelectedPinned ? "取消置顶" : "置顶", systemImage: allSelectedPinned ? "pin.slash" : "pin")
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .accessibilityIdentifier("history.batchPin")
                Button(role: .destructive) { confirmsBatchDelete = true } label: {
                    Label("删除", systemImage: "trash")
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .accessibilityIdentifier("history.batchDelete")
            }
            .disabled(selection.isEmpty)
            .buttonStyle(QuietGlassPressStyle())
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        Button {
            searchFocused = false
            onSettings()
        } label: {
            HStack(spacing: 12) {
                UserAvatar(avatarID: store.userProfile.avatarID)
                Text(store.userProfile.name).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Spacer()
                Image(systemName: "ellipsis").font(.title3).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开设置、API 与模型")
        .accessibilityIdentifier("history.settings")
        .background(Color(uiColor: .systemBackground))
    }

    private func endSelection() {
        selection = []
        selecting = false
    }

    private func exportConversation(_ conversation: Conversation) {
        do {
            let file = try ChatExportFile.create(extension: "md")
            do {
                try Data(conversation.markdown.utf8).write(to: file.url, options: .atomic)
                exportFile = file
            } catch { file.remove(); throw error }
        } catch { exportNotice = "导出失败：" + error.localizedDescription }
    }
}

private struct HistorySection: Identifiable {
    let title: String
    let chats: [Conversation]
    var id: String { title }
}
