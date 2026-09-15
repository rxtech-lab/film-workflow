import SwiftUI

/// One capability's model picker, plus the state a plain `Picker` cannot show:
/// a saved id the catalog no longer lists.
///
/// The catalog is curated server-side and changes without the app shipping,
/// while the Keychain keeps whatever was last picked forever. A `Picker` given
/// a selection no value matches renders blank, so both call sites already kept
/// the orphaned id as a row of its own — which reads as a perfectly good
/// choice, right up until the next generation is refused. This says out loud
/// what that row actually is.
struct SubscriptionModelPicker: View {
    let title: LocalizedStringKey
    /// The row for "nothing chosen" — "Select a model" where a choice is
    /// required, "Provider default" where the server picks one.
    let emptyLabel: LocalizedStringKey
    let models: [PickableModel]
    /// Whether `models` came back from the server. A saved id can only be
    /// called unavailable against a list that actually loaded — while the
    /// catalog is loading, or after it failed, an empty list says nothing.
    let isCatalogLoaded: Bool
    @Binding var selection: String

    /// Whether `selection` names a model a loaded catalog does not offer.
    ///
    /// Static so the surrounding pane can ask the same question about a picker
    /// it has not drawn yet — the section header counts stale rows before any
    /// of them exist.
    nonisolated static func isUnavailable(
        _ selection: String,
        in models: [PickableModel],
        isCatalogLoaded: Bool
    ) -> Bool {
        let saved = selection.trimmingCharacters(in: .whitespaces)
        guard isCatalogLoaded, !saved.isEmpty else { return false }
        return !models.contains { $0.id == saved }
    }

    var body: some View {
        let flagged = Self.isUnavailable(selection, in: models, isCatalogLoaded: isCatalogLoaded)
        Picker(title, selection: $selection) {
            Text(emptyLabel).tag("")
            if !selection.isEmpty, !models.contains(where: { $0.id == selection }) {
                if flagged {
                    // A `Label` rather than a suffix so the warning survives
                    // the menu's truncation of a long model id.
                    Label(selection, systemImage: "exclamationmark.triangle.fill")
                        .tag(selection)
                } else {
                    Text(selection).tag(selection)
                }
            }
            ForEach(models) { model in
                Text(model.pickerLabel).tag(model.id)
            }
        }
    }
}

/// The line under a picker holding a model the catalog has dropped.
///
/// Its own view because the two panes lay their pickers out differently — one
/// wraps the picker in an `HStack` with a refresh button — and only the warning
/// has to read the same in both.
struct UnavailableModelWarning: View {
    let model: String
    let capability: AICapability

    var body: some View {
        Label {
            Text("“\(model)” is no longer offered for \(capability.activityLabel) on your plan. Pick a replacement above — generations using it will be refused.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.caption)
        .foregroundStyle(.orange)
    }
}
