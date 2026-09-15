import SwiftUI

/// A model the account may not use for the capability that was asked for.
///
/// Same shape as `InsufficientCreditsNotice`, and for the same reason: this is
/// the second rejection that is not really a failure — the request was fine,
/// the *setting* is stale — so every surface that can hit it presents one alert
/// with one way out, instead of dropping the server's sentence into a generic
/// "Error" box the user can only dismiss.
///
/// A saved model id goes stale on its own: the catalog is curated server-side
/// and changes without the app shipping, while the Keychain keeps whatever was
/// last picked forever. So this is a state the user lands in without doing
/// anything wrong, and the only fix is the picker that chose it.
struct UnavailableModelNotice: Identifiable {
    let id = UUID()
    /// The refused id. Empty when the rejection reached the app without passing
    /// through a client that knew which model it had sent.
    let model: String
    /// Which kind of generation refused it, and therefore which Settings row
    /// chose it. Nil for the same reason `model` can be empty.
    let capability: AICapability?

    init?(_ error: Error) {
        guard let backend = error as? BackendError,
              let (model, capability) = backend.unavailableModel
        else { return nil }
        self.model = model
        self.capability = capability
    }

    var message: String {
        let named = model.isEmpty
            ? String(localized: "The model this used")
            : String(localized: "“\(model)”")
        guard let capability else {
            return String(localized: "\(named) is not available on this account. Open Settings to pick one your plan offers.")
        }
        return String(localized: "\(named) is not available for \(capability.activityLabel) on this account. Open Settings to pick a new \(capability.settingsRowLabel).")
    }
}

extension View {
    /// Presents `notice` as the alert that offers the model picker.
    ///
    /// Takes the notice rather than the error so a caller decides what counts:
    /// the same `catch` usually raises the credits alert too, and only one of
    /// the three outcomes belongs in the plain error box.
    func unavailableModelAlert(_ notice: Binding<UnavailableModelNotice?>) -> some View {
        modifier(UnavailableModelAlertModifier(notice: notice))
    }
}

private struct UnavailableModelAlertModifier: ViewModifier {
    @Binding var notice: UnavailableModelNotice?

    #if os(macOS)
        // An app cannot raise its own Settings window from `AppNavigation`; the
        // section is chosen there, the window is opened from here.
        @Environment(\.openSettings) private var openSettings
    #endif

    func body(content: Content) -> some View {
        content.alert(item: $notice) { value in
            Alert(
                title: Text("Model unavailable"),
                message: Text(value.message),
                primaryButton: .default(Text("Open Settings")) { openModelSettings() },
                secondaryButton: .cancel(Text("Dismiss"))
            )
        }
    }

    private func openModelSettings() {
        // No need to say *which* model was refused: the pane flags every
        // picker whose saved id the catalog no longer lists, which is also
        // right for the ones that haven't been tried yet.
        AppNavigation.shared.showAIProviderSettings(focus: .subscriptionModels)
        #if os(macOS)
            openSettings()
        #endif
    }
}
