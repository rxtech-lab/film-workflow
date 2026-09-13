import Foundation

/// App services must outlive the welcome/editor view that starts them. SwiftUI
/// cancels that view's task when restoring a film dismisses the welcome window.
@MainActor
final class AppServiceBootstrap {
    private var task: Task<Void, Never>?

    func run(_ operation: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        // An unstructured task retains app ownership and does not inherit the
        // waiting view task's cancellation, even if it was already cancelled.
        let task = Task { await operation() }
        self.task = task
        await task.value
    }
}
