import FilmTemplateKit
import FilmTemplateUI
import SwiftUI

/// The destination is chosen before the film or its generated media exists.
struct SimpleModeLocationPage: View {
    let session: SimpleModeSession
    let onContinue: () -> Void
    let onCancel: () -> Void
    @State private var isChoosing = false

    var body: some View {
        WizardShell(
            title: "A home for your film",
            subtitle: "Choose where to save your project and all its media.",
            current: .location,
            onCancel: onCancel
        ) {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.blue.gradient)
                        .frame(width: 100, height: 100)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                        .accessibilityHidden(true)

                    VStack(spacing: 8) {
                        Text(session.destinationURL?.deletingPathExtension().lastPathComponent
                             ?? session.intake?.projectName ?? "Your film")
                            .font(.system(size: 23, weight: .semibold))
                            .lineLimit(2)
                        Text("Your footage, edits, and generated media stay together in one film project.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(session.destinationURL == nil ? LocalizedStringKey("Choose a location") : LocalizedStringKey("Save to"))
                                    .font(.headline)
                                Text(session.destinationURL?.path(percentEncoded: false)
                                     ?? "Select a folder and name your film.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("wizard.location.path")
                            }
                            Spacer(minLength: 0)
                        }
                        Button(action: chooseLocation) {
                            Label(session.destinationURL == nil ? LocalizedStringKey("Choose Location…") : LocalizedStringKey("Change Location…"), systemImage: "folder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(isChoosing)
                        .accessibilityIdentifier("wizard.location.choose")
                        .filmTip(.simpleLocation, when: !isChoosing && session.destinationURL == nil)
                    }
                    .padding(22)
                    .background(.background.opacity(0.65), in: .rect(cornerRadius: 20))

                    if let error = session.error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("wizard.location.error")
                    }
                }
                .frame(maxWidth: 460)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        } footer: {
            Button("Back") { session.returnToBrief() }
                .accessibilityIdentifier("wizard.location.back")
            Button("Create Film", action: onContinue)
                .buttonStyle(.glassProminent)
                .disabled(session.destinationURL == nil || isChoosing)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("wizard.location.continue")
        }
    }

    private func chooseLocation() {
        FilmFeatureTip.simpleLocation.didPerform()
        isChoosing = true
        Task { @MainActor in
            defer { isChoosing = false }
            let current = session.destinationURL
            if let url = await ProjectDocumentController.shared.presentNewPanel(
                name: current?.deletingPathExtension().lastPathComponent ?? session.intake?.projectName ?? "Untitled Film",
                directory: current?.deletingLastPathComponent()
            ) {
                session.chooseDestination(url)
            }
        }
    }
}
