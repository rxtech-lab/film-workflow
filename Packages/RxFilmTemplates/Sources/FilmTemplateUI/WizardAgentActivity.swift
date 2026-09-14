import SwiftUI

public extension EnvironmentValues {
    /// The agent's transcript, shown from a button in every wizard page's
    /// header.
    ///
    /// The pages live in this package while the agent lives in the app, so the
    /// app hangs a builder here for as long as a thread exists; `nil` hides the
    /// button.
    @Entry var wizardAgentActivity: (() -> AnyView)?
}

public extension View {
    /// Gives every wizard page below this one an agent activity popover.
    func wizardAgentActivity<Content: View>(_ content: (() -> Content)?) -> some View {
        environment(\.wizardAgentActivity, content.map { build in { AnyView(build()) } })
    }
}
