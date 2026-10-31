import SwiftUI
import SeekCore

struct ReplySources: Identifiable {
    let id: UUID
    let provider: String
    let sources: [SearchResult]
}

@MainActor
struct SearchSourcesButton: View {
    let sources: [SearchResult]
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                HStack(spacing: -6) {
                    ForEach(Array(sources.prefix(3).enumerated()), id: \.offset) { index, source in
                        SourceMonogram(source: source, size: 22).zIndex(Double(3 - index))
                    }
                }
                Text("\(sources.count) 个网页").font(.system(size: 13, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 3).foregroundStyle(.primary)
        }
        .seekNativeGlassButton().controlSize(.small).tint(Color.primary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityLabel("查看 \(sources.count) 个引用网页")
    }
}

@MainActor
struct SearchSourcesView: View {
    let reply: ReplySources
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(reply.sources.enumerated()), id: \.offset) { index, source in
                        if let url = WebSearch.safeResultURL(source.url) {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack(spacing: 9) {
                                        SourceMonogram(source: source, size: 25)
                                        Text(source.siteName ?? url.host ?? "网页").font(.subheadline.weight(.medium)).lineLimit(1)
                                        if let date = source.publishedDate, !date.isEmpty {
                                            Text(String(date.prefix(10))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Text("\(index + 1)").font(.caption.monospacedDigit())
                                            .padding(5).background(.quaternary, in: Circle())
                                    }
                                    Text(source.title).font(.body.weight(.medium)).multilineTextAlignment(.leading).lineLimit(3)
                                    if !source.snippet.isEmpty {
                                        Text(source.snippet).font(.subheadline).foregroundStyle(.secondary)
                                            .lineLimit(4).multilineTextAlignment(.leading)
                                    }
                                    Text(source.url).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 22).padding(.vertical, 18)
            }
            .navigationTitle("\(reply.sources.count) 个网页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("完成", systemImage: "checkmark") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Text(reply.provider + " · 检索参考来源")
                    .font(.caption2).foregroundStyle(.secondary).padding(.bottom, 8)
            }
        }
        .seekSheetContentBackground()
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
    }
}

private struct SourceMonogram: View {
    let source: SearchResult
    let size: CGFloat
    private var label: String {
        let host = WebSearch.safeResultURL(source.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? "W"
        return String((source.siteName ?? host).prefix(1)).uppercased()
    }
    var body: some View {
        Text(label).font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.primary).frame(width: size, height: size)
            .background(Color(uiColor: .secondarySystemBackground), in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}
