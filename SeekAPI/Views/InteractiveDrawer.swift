import SwiftUI

/// UIKit owns the continuous reveal fraction; SwiftUI requests settled states.
@MainActor
struct InteractiveDrawer<Sidebar: View, Chat: View>: UIViewControllerRepresentable {
    @Binding var isOpen: Bool
    let isWide: Bool
    let isBlocked: Bool
    let sidebarWidth: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let reduceMotion: Bool
    let sidebar: Sidebar
    let chat: Chat

    func makeUIViewController(context: Context) -> DrawerController<Sidebar, Chat> {
        let controller = DrawerController(sidebar: sidebar, chat: chat, environment: context.environment)
        updateUIViewController(controller, context: context)
        return controller
    }

    func updateUIViewController(_ controller: DrawerController<Sidebar, Chat>, context: Context) {
        controller.sidebar.rootView = DrawerRoot(content: sidebar, environment: context.environment)
        controller.chat.rootView = DrawerRoot(content: chat, environment: context.environment)
        controller.onOpenChange = { isOpen = $0 }
        controller.configure(isOpen: isOpen, wide: isWide, blocked: isBlocked,
            width: sidebarWidth, top: topInset, bottom: bottomInset, reduceMotion: reduceMotion)
    }

    static func dismantleUIViewController(_ controller: DrawerController<Sidebar, Chat>, coordinator: ()) {
        controller.stopMotion()
        controller.onOpenChange = nil
    }
}

/// Carry SwiftUI environment values across the two hosting boundaries.
struct DrawerRoot<Content: View>: View {
    let content: Content
    let environment: EnvironmentValues
    var body: some View { content.environment(\.self, environment) }
}

@MainActor
final class DrawerController<Sidebar: View, Chat: View>: UIViewController, UIGestureRecognizerDelegate {
    let sidebar: UIHostingController<DrawerRoot<Sidebar>>
    let chat: UIHostingController<DrawerRoot<Chat>>
    var onOpenChange: ((Bool) -> Void)?
    private let cover = UIControl()
    private var pan: UIPanGestureRecognizer!
    private var animator: UIViewPropertyAnimator?
    private var animationID = UUID()
    private var fraction: CGFloat = 0
    private var startOffset: CGFloat = 0
    private var openBeforeDrag = false
    private var dragging = false
    private var requestedOpen = false
    private var wide = false
    private var sidebarWidth: CGFloat = 300
    private var topInset: CGFloat = 0
    private var bottomInset: CGFloat = 0
    private var reduceMotion = false
    private var lastLayout: CGRect = .zero

    init(sidebar: Sidebar, chat: Chat, environment: EnvironmentValues) {
        self.sidebar = UIHostingController(rootView: DrawerRoot(content: sidebar, environment: environment))
        self.chat = UIHostingController(rootView: DrawerRoot(content: chat, environment: environment))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.clipsToBounds = false
        for child in [sidebar as UIViewController, chat as UIViewController] {
            addChild(child)
            view.addSubview(child.view)
            child.didMove(toParent: self)
            child.view.backgroundColor = .clear
        }
        sidebar.safeAreaRegions = []
        chat.safeAreaRegions = []
        chat.view.layer.masksToBounds = true
        cover.backgroundColor = UIColor.label.withAlphaComponent(0.025)
        cover.accessibilityLabel = "关闭历史侧栏"
        cover.accessibilityTraits = .button
        cover.addTarget(self, action: #selector(closeFromTap), for: .touchUpInside)
        chat.view.addSubview(cover)
        pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)
        finishVisibility()
    }

    func configure(isOpen: Bool, wide: Bool, blocked: Bool, width: CGFloat,
                   top: CGFloat, bottom: CGFloat, reduceMotion: Bool) {
        loadViewIfNeeded()
        let changed = self.wide != wide || sidebarWidth != width || topInset != top || bottomInset != bottom
        if changed { stopMotion() }
        self.wide = wide
        sidebarWidth = max(width, 1)
        topInset = top
        bottomInset = bottom
        self.reduceMotion = reduceMotion
        pan.isEnabled = !wide && !blocked
        if changed { layoutChildren() }
        if wide {
            requestedOpen = false
            apply(0)
            finishVisibility()
        } else if requestedOpen != isOpen {
            requestedOpen = isOpen
            if !dragging { settle(open: isOpen) }
        } else if changed && !dragging {
            settle(open: isOpen)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard lastLayout != view.bounds else { return }
        stopMotion()
        layoutChildren()
        if !dragging { settle(open: requestedOpen) }
    }

    private func layoutChildren() {
        lastLayout = view.bounds
        let size = view.bounds.size
        sidebar.view.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: size.height)
        let chatWidth = max(1, size.width - (wide ? sidebarWidth : 0))
        let chatHeight = size.height + topInset + bottomInset
        chat.view.bounds = CGRect(x: 0, y: 0, width: chatWidth, height: chatHeight)
        chat.view.center = CGPoint(x: chatWidth / 2, y: (size.height + bottomInset - topInset) / 2)
        cover.frame = chat.view.bounds
        chat.view.bringSubviewToFront(cover)
        apply(fraction)
    }

    private func apply(_ progress: CGFloat) {
        fraction = min(1, max(0, progress))
        chat.view.transform = CGAffineTransform(translationX: wide ? sidebarWidth : fraction * sidebarWidth, y: 0)
        chat.view.layer.cornerRadius = wide ? 0 : 32 * fraction
        cover.alpha = wide ? 0 : fraction
    }

    /// Freeze the live presentation, not its target, before another drag starts.
    func stopMotion() {
        guard let animator else { return }
        let liveX = chat.view.layer.presentation()?.affineTransform().tx ?? chat.view.transform.tx
        let live = wide ? fraction : min(1, max(0, liveX / sidebarWidth))
        animationID = UUID()
        animator.stopAnimation(true)
        self.animator = nil
        UIView.performWithoutAnimation { apply(live) }
    }

    private func settle(open: Bool) {
        stopMotion()
        let target: CGFloat = open ? 1 : 0
        sidebar.view.isHidden = false
        chat.view.bringSubviewToFront(cover)
        cover.isHidden = wide
        chat.view.accessibilityElementsHidden = !wide && open
        sidebar.view.accessibilityElementsHidden = !wide && !open
        sidebar.view.accessibilityViewIsModal = !wide && open
        guard !wide, !reduceMotion, abs(fraction - target) > 0.001, view.window != nil else {
            apply(wide ? 0 : target)
            finishVisibility()
            return
        }
        let token = UUID()
        animationID = token
        let duration = max(0.18, 0.38 * Double(abs(fraction - target)))
        let motion = UIViewPropertyAnimator(duration: duration, dampingRatio: 0.86) { [weak self] in self?.apply(target) }
        motion.addCompletion { [weak self] _ in
            guard let self, self.animationID == token else { return }
            self.animator = nil
            self.finishVisibility()
        }
        animator = motion
        motion.startAnimation()
    }

    private func finishVisibility() {
        sidebar.view.isHidden = !wide && fraction <= 0.001
        cover.isHidden = wide || fraction <= 0.001
        sidebar.view.accessibilityElementsHidden = !wide && fraction < 0.5
        chat.view.accessibilityElementsHidden = !wide && fraction >= 0.5
        sidebar.view.accessibilityViewIsModal = !wide && fraction >= 0.5
    }

    @objc private func closeFromTap() {
        requestedOpen = false
        onOpenChange?(false)
        settle(open: false)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            stopMotion()
            dragging = true
            openBeforeDrag = requestedOpen
            startOffset = fraction * sidebarWidth
            sidebar.view.isHidden = false
            cover.isHidden = false
            view.endEditing(true)
        case .changed:
            let offset = startOffset + gesture.translation(in: view).x
            UIView.performWithoutAnimation { apply(offset / sidebarWidth) }
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            let projected = fraction * sidebarWidth + gesture.velocity(in: view).x * 0.15
            let open = gesture.state == .ended ? projected > sidebarWidth / 2 : openBeforeDrag
            requestedOpen = open
            onOpenChange?(open)
            settle(open: open)
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === pan, !wide else { return false }
        let velocity = pan.velocity(in: view)
        guard abs(velocity.x) > abs(velocity.y) * 1.35 else { return false }
        if animator != nil { return true }
        return fraction <= 0.001 ? velocity.x > 0 : (fraction >= 0.999 ? velocity.x < 0 : true)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let current = target, current !== view {
            if current is UISlider || current is UITextField || current is UITextView { return false }
            if let scroll = current as? UIScrollView, scroll.contentSize.width > scroll.bounds.width + 1 { return false }
            target = current.superview
        }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is UIPanGestureRecognizer && otherGestureRecognizer.view is UIScrollView
    }
}
