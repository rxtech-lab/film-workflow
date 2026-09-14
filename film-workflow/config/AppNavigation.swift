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
        case account
        case aiProvider
        case agent
        case captions
        case remotion
        case mcp

        var id: String { rawValue }
    }

    /// A specific control to reveal once a settings section is showing.
    enum SettingsFocus: String, Hashable {
        case whisperModels
        /// The subscription model pickers, asked for when a generation was
        /// refused because the id one of them holds is no longer offered.
        case subscriptionModels
    }

    var settingsSection: SettingsSection = .account

    /// Bumped by `requestSignIn()`. The active window's `signInSheetPresenter`
    /// watches it and raises the sign-in sheet.
    private(set) var signInRequestCount = 0
    private var handledSignInRequestCount = 0
    private(set) var topUpRequestCount = 0
    private var handledTopUpRequestCount = 0

    /// What the app is currently showing, so the agent window can follow along.
    ///
    /// Set by each tab as its project selection changes. Only ever used to seed
    /// a **new** thread — an existing thread keeps whatever it was pointed at,
    /// so switching tabs can't retarget a turn that is already running.
    var currentTarget: AgentTarget = .none
    var pendingAgentThreadID: UUID?
    /// Where the Welcome window should open, when something outside it asks —
    /// the New Film menu item, or the Simple mode What's New card.
    ///
    /// Carries a counter rather than being a plain optional: the window may not
    /// exist yet, in which case its first render already sees the route and no
    /// change fires. The count makes every request distinct, so asking twice
    /// works whether the window was open or not.
    private(set) var pendingWelcomeRoute: WelcomeRoute?
    private(set) var welcomeRouteRequestCount = 0

    func requestWelcomeRoute(_ route: WelcomeRoute) {
        pendingWelcomeRoute = route
        welcomeRouteRequestCount += 1
    }

    /// Takes the route, if one is waiting.
    func consumeWelcomeRoute() -> WelcomeRoute? {
        defer { pendingWelcomeRoute = nil }
        return pendingWelcomeRoute
    }

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
    }

    /// Opens the AI provider settings, where the endpoint and key live.
    ///
    /// Same macOS caveat as `showCaptionSettings`: the caller must also invoke
    /// `openSettings()` from the environment.
    func showAIProviderSettings(focus: SettingsFocus? = nil) {
        settingsSection = .aiProvider
        pendingSettingsFocus = focus
    }

    func showAccountSettings() {
        settingsSection = .account
        pendingSettingsFocus = nil
    }

    /// Asks the active window to present the dedicated sign-in sheet.
    func requestSignIn() {
        signInRequestCount += 1
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.sheetParent == nil }
        window?.makeKeyAndOrderFront(nil)
        #endif
    }

    /// Only one window consumes a request; requests wait while another sheet is open.
    func consumeSignInRequest() -> Bool {
        guard handledSignInRequestCount < signInRequestCount else { return false }
        handledSignInRequestCount = signInRequestCount
        return true
    }

    /// Asks the active window to present the top-up sheet. Raised the same way
    /// as sign-in so the Account menu, which has no view of its own, can do it.
    func requestTopUp() {
        topUpRequestCount += 1
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey && $0.sheetParent == nil }
        window?.makeKeyAndOrderFront(nil)
        #endif
    }

    func consumeTopUpRequest() -> Bool {
        guard handledTopUpRequestCount < topUpRequestCount else { return false }
        handledTopUpRequestCount = topUpRequestCount
        return true
    }
}
