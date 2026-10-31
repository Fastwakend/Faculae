import SwiftUI

@main
@MainActor
struct SeekAPIApp: App {
    @UIApplicationDelegateAdaptor(SeekAppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(SeekTheme.blue)
                .task { store.enterForeground() }
                .onOpenURL { store.openConversationURL($0) }
                .onChange(of: phase) { _, next in
                    if next == .background { store.enterBackground() }
                    else if next == .active { store.enterForeground() }
                }
        }
    }
}
