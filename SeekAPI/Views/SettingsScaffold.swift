import SwiftUI

/// One header, foreground and navigation treatment for every settings level.
@MainActor
struct SettingsScaffold<Content: View>: View {
    let title: String
    var isRoot = false
    var onSave: (() -> Void)? = nil
    var saveDisabled = false
    @ViewBuilder var content: () -> Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            SeekGlassGroup {
                ZStack {
                    Text(title).font(.title3.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, 58)
                    HStack {
                        if !isRoot {
                            CircleIconButton(symbol: "chevron.left", label: onSave == nil ? "返回" : "取消编辑") { dismiss() }
                        }
                        Spacer()
                        if let onSave {
                            CircleIconButton(symbol: "checkmark", label: "保存", action: onSave)
                                .disabled(saveDisabled).accessibilityIdentifier("settings.save")
                        } else if isRoot {
                            CircleIconButton(symbol: "xmark", label: "关闭设置") { dismiss() }
                                .accessibilityIdentifier("settings.close")
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)
            }
            content().scrollContentBackground(.hidden)
        }
        .foregroundStyle(Color(uiColor: .label))
        .tint(Color(uiColor: .label))
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        // Feedback observes navigation completion, never competes with the
        // NavigationLink/Button tap recognizer on its label or row.
        .onAppear { if !isRoot { Haptics.shared.play(.listItem) } }
    }
}
