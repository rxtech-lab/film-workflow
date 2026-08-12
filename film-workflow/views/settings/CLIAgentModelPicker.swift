#if os(macOS)
import SwiftUI

/// Picks the model for one command-line agent backend.
///
/// Shared by the Claude Code and Codex rows because they differ in exactly one
/// thing — whether there is a list to refresh — and that is a parameter, not a
/// second view.
///
/// Two rows exist that aren't models. An empty selection means "don't pass
/// `--model` at all", which is not the same as naming the CLI's default alias:
/// it leaves whatever the user set in the CLI itself alone. And "Custom…" keeps
/// a brand-new model reachable the day it ships, rather than the day this app
/// next updates its list.
struct CLIAgentModelPicker: View {
    let title: LocalizedStringKey
    let options: [AgentModelOption]
    @Binding var selection: String
    var isLoading = false
    var errorMessage: String?
    /// Codex only. Nil hides the refresh button — Claude Code has no list to
    /// fetch.
    var onRefresh: (() -> Void)?

    /// Tag for the "Custom…" row. A model id can't collide with it: the CLIs
    /// don't accept spaces, and this is never saved.
    private static let customTag = "\u{0}custom"

    @State private var isCustom = false

    var body: some View {
        HStack {
            Picker(title, selection: pickerSelection) {
                Text("Use the CLI's own default").tag("")

                // A model saved before it left the list — or typed by hand —
                // keeps its own row so the picker never silently reassigns it.
                if !selection.isEmpty, !options.contains(where: { $0.id == selection }) {
                    Text(selection).tag(selection)
                }

                ForEach(options) { option in
                    Text(option.displayName).tag(option.id)
                }

                Divider()
                Text("Custom…").tag(Self.customTag)
            }

            if let onRefresh {
                Button(action: onRefresh) {
                    if isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .help("Refresh model list")
            }
        }

        if isCustom {
            TextField("Model id", text: $selection)
                .textFieldStyle(.roundedBorder)
        }

        if let errorMessage {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Intercepts the "Custom…" tag so it flips the text field on instead of
    /// becoming the selection.
    private var pickerSelection: Binding<String> {
        Binding(
            get: { isCustom ? Self.customTag : selection },
            set: { newValue in
                if newValue == Self.customTag {
                    isCustom = true
                } else {
                    isCustom = false
                    selection = newValue
                }
            }
        )
    }
}
#endif
