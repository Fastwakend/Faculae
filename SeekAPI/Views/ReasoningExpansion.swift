import SwiftUI

struct ChatControlAnchors {
    var reasoning: Anchor<CGRect>?
    var imageParameters: Anchor<CGRect>?
    var composer: Anchor<CGRect>?
    var controls: Anchor<CGRect>?
}

struct ChatControlAnchorsKey: PreferenceKey {
    static let defaultValue = ChatControlAnchors()

    static func reduce(value: inout ChatControlAnchors, nextValue: () -> ChatControlAnchors) {
        let next = nextValue()
        value.reasoning = next.reasoning ?? value.reasoning
        value.imageParameters = next.imageParameters ?? value.imageParameters
        value.composer = next.composer ?? value.composer
        value.controls = next.controls ?? value.controls
    }
}

/// One persistent native glass surface grows from the button into the panel.
/// Animate its geometry directly instead of replacing two conditional effects:
/// their insertion/removal can lose the morph and fall back to an instant swap.
/// The Slider stays mounted, unscaled, at its final coordinates.
@available(iOS 26, *)
@MainActor
struct ReasoningExpansion<Source: View>: View {
    let store: AppStore
    @Binding var isPresented: Bool
    @State private var contentHeight: CGFloat = 240
    let sourceBounds: CGRect
    let controlsBounds: CGRect
    let viewport: CGSize
    let topSafeArea: CGFloat
    let source: Source
    let onOpen: () -> Void
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var panelWidth: CGFloat { min(360, max(1, viewport.width - 32)) }
    // The destination overlaps the input area, like a native composer Menu.
    // Only the source's bottom is used. Changing the label's width cannot shift
    // the panel, while keyboard and window-height changes still move it safely.
    private var panelBottom: CGFloat { max(1, min(sourceBounds.maxY, viewport.height - 12)) }
    private var panelHeight: CGFloat { min(contentHeight, max(1, panelBottom - topSafeArea - 12)) }
    private var visibleSource: CGRect { sourceBounds.intersection(controlsBounds) }
    private var sourceIsVisible: Bool { !visibleSource.isNull && !visibleSource.isEmpty }
    private var collapsedBounds: CGRect {
        sourceIsVisible ? visibleSource : CGRect(x: sourceBounds.midX, y: sourceBounds.midY, width: 0, height: 0)
    }
    private var panelBounds: CGRect {
        CGRect(x: (viewport.width - panelWidth) / 2, y: panelBottom - panelHeight,
               width: panelWidth, height: panelHeight)
    }
    private var surfaceBounds: CGRect { isPresented ? panelBounds : collapsedBounds }
    private var surfaceCornerRadius: CGFloat { isPresented ? 26 : collapsedBounds.height / 2 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { isPresented = false }
                .allowsHitTesting(isPresented)
                .accessibilityHidden(true)

            GlassEffectContainer(spacing: 0) {
                Button(action: open) {
                    Color.clear
                        .frame(width: surfaceBounds.width, height: surfaceBounds.height)
                        .overlay {
                            // Title travels with the surface without stretching.
                            // There is no second title/button waiting underneath.
                            source
                                .frame(width: sourceBounds.width, height: sourceBounds.height)
                                .offset(x: sourceBounds.midX - collapsedBounds.midX)
                                .frame(width: collapsedBounds.width, height: collapsedBounds.height)
                                .clipped()
                                .opacity(isPresented ? 0 : 1)
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isPresented)
                        }
                }
                .buttonStyle(.plain)
                .contentShape(RoundedRectangle(cornerRadius: surfaceCornerRadius))
                .glassEffect(.regular.interactive(!isPresented), in: .rect(cornerRadius: surfaceCornerRadius))
                .glassEffectID("reasoning", in: glassNamespace)
                .glassEffectTransition(.matchedGeometry)
                .position(x: surfaceBounds.midX, y: surfaceBounds.midY)
                // Stable identity makes frame, center and corner radius animate
                // on every reversal, without depending on an insertion transition.
                .animation(animation, value: isPresented)
                .opacity(isPresented || sourceIsVisible ? 1 : 0)
                .disabled(store.isStreaming)
                .allowsHitTesting(!isPresented && sourceIsVisible)
                .accessibilityHidden(isPresented || !sourceIsVisible)
                .accessibilityLabel("调整推理等级")
                .accessibilityValue(store.selectedProfile.explicitReasoningLevel?.title ?? "自动")
                .accessibilityIdentifier("chat.reasoning")
            }
            .frame(width: viewport.width, height: viewport.height)

            ScrollView {
                ReasoningSettings(store: store)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        guard height > 0, abs(contentHeight - height) > 0.5 else { return }
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { contentHeight = height }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: panelWidth, height: panelHeight)
            .mask {
                // Reveal content through the same expanding outline. This only
                // clips pixels; it never relayouts or scales the native Slider.
                RoundedRectangle(cornerRadius: surfaceCornerRadius)
                    .frame(width: surfaceBounds.width, height: surfaceBounds.height)
                    .position(x: surfaceBounds.midX - panelBounds.minX,
                              y: surfaceBounds.midY - panelBounds.minY)
                    .frame(width: panelWidth, height: panelHeight)
                    .animation(animation, value: isPresented)
            }
            .opacity(isPresented ? 1 : 0)
            // Hide content immediately on close. Only an empty native glass
            // surface returns to the button; no Slider/labels fold over its title.
            .animation(isPresented && !reduceMotion ? .easeOut(duration: 0.12) : nil, value: isPresented)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
            .accessibilityAddTraits(isPresented ? .isModal : [])
            .position(x: viewport.width / 2, y: panelBottom - panelHeight / 2)
        }
        .accessibilityAction(.escape) { isPresented = false }
        .onChange(of: isPresented) { _, _ in Haptics.shared.play() }
    }

    private var animation: Animation? {
        reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.72)
    }

    private func open() {
        guard !store.isStreaming else { return }
        onOpen()
        isPresented = true
    }
}
