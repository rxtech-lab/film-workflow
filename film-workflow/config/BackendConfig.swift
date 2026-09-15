import Foundation

nonisolated enum BackendConfig {
    private static func value(_ key: String, fallback: String) -> String {
        let raw = (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, !raw.contains("$(") else { return fallback }
        return raw
    }

    #if DEBUG
    private static let defaultAPIBaseURL = "http://localhost:3000"
    private static let defaultWebBaseURL = "http://localhost:3000"
    #else
    private static let defaultAPIBaseURL = "https://filmstudio.rxlab.app"
    private static let defaultWebBaseURL = "https://filmstudio.rxlab.app"
    #endif

    static var apiBaseURL: URL {
        URL(string: value("AppAPIBaseURL", fallback: defaultAPIBaseURL))!
    }

    static var webBaseURL: URL {
        URL(string: value("AppWebBaseURL", fallback: defaultWebBaseURL))!
    }

    static var oidcIssuer: String {
        value("AppAuthIssuer", fallback: "https://auth.rxlab.app")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static var clientID: String {
        value("AppAuthClientID", fallback: "filmstudio-macos")
    }

    static var redirectURI: String {
        value("AppAuthRedirectURI", fallback: "filmstudio://callback")
    }

    /// rxlab-auth rejects the whole token exchange when any requested scope is
    /// outside the client's allow-list, so this stays at the one scope every
    /// client is granted. `offline_access` in particular does not exist on that
    /// server — refresh tokens are issued unconditionally.
    ///
    /// Add `email` here only after granting it to the client in the rxauth
    /// admin console; it is what puts the address (rather than the display
    /// name) in the account menu.
    static var scopes: [String] {
        value("AppAuthScopes", fallback: "openid")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    static var hasOAuthConfiguration: Bool {
        URL(string: oidcIssuer)?.scheme != nil
            && !clientID.isEmpty
            && URL(string: redirectURI)?.scheme != nil
    }

    // MARK: - RxSubscription

    /// The rx-subscription service the paywall, plan catalog and top-ups come
    /// from. Unlike the app backend this has no localhost equivalent, so DEBUG
    /// and release builds both point at production.
    static var subscriptionURL: URL {
        URL(string: value("AppSubscriptionURL", fallback: "https://subscription.rxlab.app"))!
    }

    /// The publishable key minted for this app in the RxSubscription console.
    ///
    /// Publishable keys are meant to ship inside the binary: on their own they
    /// authenticate nothing, and every request also carries the signed-in
    /// user's access token, whose OAuth client must be on the key's allow-list.
    static var subscriptionPublishableKey: String {
        #if DEBUG
        // Lets a developer point a debug run at their own key from the scheme
        // without editing (and accidentally committing) Base.xcconfig.
        if let override = ProcessInfo.processInfo.environment["APP_SUBSCRIPTION_PUBLISHABLE_KEY"],
           !override.isEmpty {
            return override
        }
        #endif
        return value("AppSubscriptionPublishableKey", fallback: "")
    }

    /// Whether the subscription service can be called at all. When false the
    /// app degrades to its pre-subscription behaviour rather than failing: the
    /// gate stays open and credits are bought on the web as before.
    static var hasSubscriptionConfiguration: Bool {
        hasSubscriptionConfiguration(key: subscriptionPublishableKey, url: subscriptionURL)
    }

    /// Split from the property so tests can exercise the rule without a bundle.
    static func hasSubscriptionConfiguration(key: String, url: URL?) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains("$(") && url?.scheme != nil
    }

    /// The `Accept-Language` every request to our backend carries.
    ///
    /// The languages are the bundle's, not the system's: they are what the app
    /// is actually drawn in, so a marketplace title, a taxonomy label or a
    /// refusal comes back in the language the window around it is already in.
    /// The server answers in the first one it has, and falls back to the text
    /// as an admin typed it where nobody has translated a row yet.
    static var acceptLanguage: String {
        acceptLanguage(for: Bundle.main.preferredLocalizations)
    }

    /// The header value for an ordered list of language tags, most wanted
    /// first, as `zh-Hans,en;q=0.9`. Anything past the fourth is dropped: no
    /// backend negotiates that far down, and the header stays readable.
    static func acceptLanguage(for languages: [String]) -> String {
        let tags = languages.filter { !$0.isEmpty && $0 != "Base" }.prefix(4)
        guard !tags.isEmpty else { return "en" }
        return tags.enumerated().map { index, tag in
            index == 0 ? tag : "\(tag);q=\(String(format: "%.1f", 1 - Double(index) / 10))"
        }.joined(separator: ",")
    }

    static var diagnostics: String {
        // The key itself is never logged — only whether one is present.
        "issuer=\(oidcIssuer), client=\(clientID), redirect=\(redirectURI), "
            + "api=\(apiBaseURL.absoluteString), "
            + "subscription=\(subscriptionURL.host ?? "-") key=\(hasSubscriptionConfiguration ? "set" : "missing")"
    }
}
