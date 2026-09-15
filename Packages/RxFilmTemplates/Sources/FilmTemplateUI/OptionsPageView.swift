import FilmTemplateKit
import JSONRenderUI
import SwiftUI

/// The agent-authored page of choices: footage mapping, style, music.
public struct OptionsPageView: View {
    let title: String
    let spec: JSONRenderSpec
    let state: JSONRenderState
    let imageProvider: JSONRenderImageProvider?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    public init(
        title: String,
        spec: JSONRenderSpec,
        state: JSONRenderState,
        imageProvider: JSONRenderImageProvider? = nil,
        onConfirm: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.spec = spec
        self.state = state
        self.imageProvider = imageProvider
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public var body: some View {
        WizardShell(
            title: LocalizedStringKey(title),
            subtitle: "Choose how your film should look. You can change any of it later.",
            current: .chooseOptions,
            onCancel: onCancel
        ) {
            ScrollView {
                JSONRenderView(spec: spec, state: state, imageProvider: imageProvider)
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("wizard.options")
        } footer: {
            Button("Build My Film") {
                FilmTemplateTip.options.didPerform()
                onConfirm()
            }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.options.confirm")
                .templateTip(.options)
        }
    }
}

/// The fallback when the agent could not produce a page it can draw twice in a
/// row: let the user go ahead on the agent's own recommendation rather than
/// stranding them on a broken step.
public struct OptionsFallbackView: View {
    let detail: String
    let onContinue: () -> Void
    let onCancel: () -> Void

    public init(detail: String, onContinue: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.detail = detail
        self.onContinue = onContinue
        self.onCancel = onCancel
    }

    public var body: some View {
        WizardShell(
            title: "Choose how it looks",
            subtitle: nil,
            current: .chooseOptions,
            onCancel: onCancel
        ) {
            VStack(spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.secondary)
                Text("We'll use our recommended setup")
                    .font(.system(size: 15, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } footer: {
            Button("Build My Film", action: onContinue)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.options.confirm")
        }
    }
}
