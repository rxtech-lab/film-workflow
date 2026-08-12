#if os(macOS)
import Sparkle

/// Wraps Sparkle's updater for the macOS app.
///
/// Instantiating the controller with `startingUpdater: true` also starts the
/// scheduled background check, so launching the app is enough to pick up a new
/// release; `checkForUpdates()` backs the explicit menu command.
///
/// The feed lives at the `SUFeedURL` baked into Info.plist
/// (https://update.filmstudio.rxlab.app/appcast.xml) and is verified against the
/// `SUPublicEDKey` there — CI signs each build with the matching private key.
@MainActor
final class UpdateService {
    static let shared = UpdateService()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
