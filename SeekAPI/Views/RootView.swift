import SwiftUI

@MainActor
struct RootView: View {
    let store: AppStore
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("appearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("chatTextSize") private var textSize = ChatTextSize.standard.rawValue
    @State private var showsHistory = false
    @State private var sheet: RootSheet?
    @State private var chatPresentation = false

    var body: some View {
        GeometryReader { geometry in
            let wide = sizeClass == .regular && geometry.size.width >= 700
            let sidebarWidth: CGFloat = wide ? 300 : min(geometry.size.width * 0.82, 360)
            InteractiveDrawer(isOpen: $showsHistory, isWide: wide,
                isBlocked: chatPresentation || sheet != nil,
                sidebarWidth: sidebarWidth, topInset: geometry.safeAreaInsets.top,
                bottomInset: geometry.safeAreaInsets.bottom, reduceMotion: reduceMotion,
                sidebar: HistoryView(store: store, onSelect: closeHistory, onSettings: { sheet = .settings }),
                chat: ChatView(store: store, topSafeArea: geometry.safeAreaInsets.top,
                    bottomSafeArea: geometry.safeAreaInsets.bottom, showsHistoryButton: !wide,
                    onHistory: { showsHistory = true }, onSettings: { sheet = .settings },
                    onPresentationChange: { chatPresentation = $0 }))
                .onChange(of: wide) { _, _ in showsHistory = false }
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .onChange(of: showsHistory) { _, _ in Haptics.shared.play(.sidebar) }
        .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        .environment(\.chatTextScale, (ChatTextSize(rawValue: textSize) ?? .standard).scale)
        .sheet(item: $sheet) { item in
            Group {
                switch item {
                case .settings: NavigationStack { SettingsView(store: store) }
                case .files(let batch): ExternalFileImportView(batch: batch, store: store) { sheet = nil }
                }
            }
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .preferredColorScheme((AppAppearance(rawValue: appearance) ?? .system).colorScheme)
        }
        .onOpenURL { url in
            if url.scheme == "seekapi" { showsHistory = false; sheet = nil }
        }
        .onChange(of: store.externalFiles.pending?.id, initial: true) { _, _ in
            guard let batch = store.externalFiles.pending else { return }
            showsHistory = false
            sheet = .files(batch)
        }
        .onChange(of: store.externalFiles.failure) { _, failure in
            if let failure { store.notice = failure; store.externalFiles.failure = nil }
        }
        .alert("提示", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("知道了", role: .cancel) { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    private func closeHistory() { showsHistory = false }
}

private enum RootSheet: Identifiable {
    case settings
    case files(ExternalFileBatch)
    var id: String {
        switch self {
        case .settings: return "settings"
        case .files(let batch): return batch.id.uuidString
        }
    }
}
