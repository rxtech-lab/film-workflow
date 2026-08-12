import Observation
import SwiftUI

/// Cross-screen navigation requests: lets a view deep inside one tab send the
/// user somewhere else, e.g. "no Whisper model downloaded — take me to the
/// download list".
///
/// A `@MainActor @Observable` singleton for the same reason `CaptionSettings` is
/// one: the alternative is threading a binding down through every intermediate
/// view that otherwise has no reason to know navigation exists.
@Observable
@MainActor
final class AppNavigation {
    static let shared = AppNavigation()

    /// The tabs of `SettingsView`, so a caller can ask for one by name.
    enum SettingsSection: String, Hashable, CaseIterable, Identifiable {
        case aiProvider
        case captions
        case mcp

        var id: String { rawValue }
    }

    /// A specific control to reveal once a settings section is showing.
    enum SettingsFocus: String, Hashable {
        case whisperModels
    }

    /// The selected top-level tab. Only settable to `.Settings` on iOS, where
    /// Settings is a tab; on macOS it's a separate window with no tab to select.
    var tab: Tabs = .Music

    var settingsSection: SettingsSection = .aiProvider

    /// Consumed by the settings view once it has scrolled to the target, so
    /// reopening Settings later doesn't jump around unprompted.
    var pendingSettingsFocus: SettingsFocus?

    private init() {}

    /// Opens caption settings, optionally scrolling to the Whisper model list.
    ///
    /// On macOS the caller must also invoke `openSettings()` from the
    /// environment — an app can't raise its own Settings window from here.
    func showCaptionSettings(focus: SettingsFocus? = nil) {
        settingsSection = .captions
        pendingSettingsFocus = focus
        #if !os(macOS)
            tab = .Settings
        #endif
    }
}
