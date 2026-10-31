import SwiftUI
import Observation

@MainActor
@Observable
final class TranscriptScrollContext {
    var scrollView: UIScrollView?
}

/// Register the actual header with UIKit's scroll-edge compositor. The soft
/// edge is the public system progressive blur, including the status-bar area.
@MainActor
struct NativeScrollHeader<Content: View>: UIViewControllerRepresentable {
    let scrollView: UIScrollView?
    let content: Content

    init(scrollContext: TranscriptScrollContext, @ViewBuilder content: () -> Content) {
        self.scrollView = scrollContext.scrollView
        self.content = content()
    }

    func makeUIViewController(context: Context) -> HeaderController<Content> {
        let controller = HeaderController(rootView: content)
        controller.safeAreaRegions = []
        controller.view.backgroundColor = .clear
        controller.connect(to: scrollView)
        return controller
    }

    func updateUIViewController(_ controller: HeaderController<Content>, context: Context) {
        controller.rootView = content
        controller.connect(to: scrollView)
    }

    final class HeaderController<Header: View>: UIHostingController<Header> {
        private var edgeInteraction: (any UIInteraction)?

        func connect(to scrollView: UIScrollView?) {
            if #available(iOS 26, *) {
                let interaction: UIScrollEdgeElementContainerInteraction
                if let existing = edgeInteraction as? UIScrollEdgeElementContainerInteraction {
                    interaction = existing
                } else {
                    interaction = UIScrollEdgeElementContainerInteraction()
                    interaction.edge = .top
                    view.addInteraction(interaction)
                    edgeInteraction = interaction
                }
                interaction.scrollView = scrollView
            }
        }
    }
}
