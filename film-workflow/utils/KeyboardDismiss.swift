import SwiftUI

#if os(iOS)
import UIKit

private final class KeyboardDismissCoordinator {
    static let shared = KeyboardDismissCoordinator()
    private var attachedWindows = Set<ObjectIdentifier>()

    func attach() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    let id = ObjectIdentifier(window)
                    if self.attachedWindows.contains(id) { continue }
                    let tap = UITapGestureRecognizer(target: window, action: #selector(UIView.endEditing))
                    tap.cancelsTouchesInView = false
                    tap.requiresExclusiveTouchType = false
                    window.addGestureRecognizer(tap)
                    self.attachedWindows.insert(id)
                }
            }
        }
    }
}

private struct KeyboardDismissModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.immediately)
            .onAppear { KeyboardDismissCoordinator.shared.attach() }
    }
}
#endif

extension View {
    /// Dismisses the keyboard when the user taps outside a text input or scrolls.
    /// Apply once near the app root.
    func dismissKeyboardOnTapAndScroll() -> some View {
        #if os(iOS)
        modifier(KeyboardDismissModifier())
        #else
        self
        #endif
    }
}
