import FilmTemplateKit
import SwiftUI

/// Shown when the agent looked and found no project template worth offering.
///
/// The marketplace can be empty, or hold nothing that suits this company. Both
/// used to strand the run on the research spinner, because presenting an empty
/// list is refused and the options page does not belong in that phase yet. The
/// film is still buildable — the agent plans the shots itself — so this says
/// what happened and offers to go on.
public struct TemplatesUnavailableView: View {
    let reason: String
    let onContinue: () -> Void
    let onCancel: () -> Void

    public init(reason: String, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.reason = reason
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    public var body: some View {
        WizardShell(
            title: "Pick a template",
            subtitle: nil,
            current: .chooseTemplate,
            onCancel: onCancel
        ) {
            VStack(spacing: 12) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text("No template fitted this one")
                    .font(.system(size: 15, weight: .semibold))
                Text(LocalizedStringKey(reason))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Text("We can build it from your brief and your own footage instead.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("wizard.templates.unavailable")
        } footer: {
            Button("Build Without a Template", action: onContinue)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.templates.continue")
        }
    }
}
