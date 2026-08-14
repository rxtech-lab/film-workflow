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

    static var diagnostics: String {
        "issuer=\(oidcIssuer), client=\(clientID), redirect=\(redirectURI), api=\(apiBaseURL.absoluteString)"
    }
}
