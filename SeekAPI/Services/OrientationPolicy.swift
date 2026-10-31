import UIKit

@MainActor
enum OrientationPolicy {
    static var supported: UIInterfaceOrientationMask {
        if UserDefaults.standard.bool(forKey: "portraitLocked") { return .portrait }
        return UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                update(window.rootViewController)
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supported)) { error in
                // Multitasking/system transitions can temporarily deny a request.
                // The delegate mask continues to enforce the preference afterward.
                NSLog("Orientation update: %@", error.localizedDescription)
            }
        }
    }

    private static func update(_ controller: UIViewController?) {
        guard let controller else { return }
        controller.setNeedsUpdateOfSupportedInterfaceOrientations()
        controller.children.forEach { update($0) }
        update(controller.presentedViewController)
    }
}
