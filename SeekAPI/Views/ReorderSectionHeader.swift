import SwiftUI

@MainActor
struct ReorderSectionHeader: View {
    let title: String
    @Binding var isReordering: Bool
    let canReorder: Bool
    let accessibilityID: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                Haptics.shared.play(.listItem)
                withAnimation(.snappy(duration: 0.2)) { isReordering.toggle() }
            } label: {
                Label(isReordering ? "完成" : "排序", systemImage: isReordering ? "checkmark" : "arrow.up.arrow.down")
                    .font(.caption.weight(.medium))
            }
            .seekNativeGlassButton().controlSize(.mini)
            .textCase(nil)
            .disabled(!canReorder && !isReordering)
            .accessibilityLabel(title + (isReordering ? "完成排序" : "拖动排序"))
            .accessibilityIdentifier(accessibilityID)
        }
    }
}
