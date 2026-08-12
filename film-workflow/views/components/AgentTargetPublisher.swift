import SwiftUI

/// Publishes what a tab is currently showing, so the agent window can follow.
///
/// This is the "follows context" half of the system-wide window: a thread
/// started while you are looking at a caption project already knows which
/// project you mean, without you having to pick it again. It only ever seeds a
/// **new** thread — existing threads keep their own target, so switching tabs
/// can never retarget work already running.
private struct AgentTargetPublisher: ViewModifier {
    let target: AgentTarget

    func body(content: Content) -> some View {
        content
            .onAppear { AppNavigation.shared.currentTarget = target }
            .onChange(of: target) { _, updated in
                AppNavigation.shared.currentTarget = updated
            }
    }
}

extension View {
    func publishesAgentTarget(_ target: AgentTarget) -> some View {
        modifier(AgentTargetPublisher(target: target))
    }

    /// Convenience for the four tabs whose projects have no explicit id and are
    /// addressed by `MCPProjectHandlers.stableID`.
    func publishesAgentTarget(
        kind: AgentTargetKind,
        projectUUID: UUID?
    ) -> some View {
        publishesAgentTarget(
            projectUUID.map { AgentTarget(kind: kind, projectUUID: $0) } ?? .none
        )
    }
}
