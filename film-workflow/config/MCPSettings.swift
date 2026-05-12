import Foundation
import Observation
import Security

/// Persisted configuration for the embedded MCP server.
///
/// `enabled`, `bindAll`, and `basePort` live in UserDefaults; the bearer
/// token lives in the Keychain (mirroring `AppConfig`'s pattern).
@MainActor
@Observable
final class MCPSettings {
    static let shared = MCPSettings()

    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Keys.enabled)
            if enabled, (try? Self.loadToken()) == nil || (try? Self.loadToken())?.isEmpty == true {
                _ = try? Self.regenerateToken()
            }
            notify()
        }
    }

    var bindAll: Bool {
        didSet {
            guard bindAll != oldValue else { return }
            UserDefaults.standard.set(bindAll, forKey: Keys.bindAll)
            notify()
        }
    }

    var basePort: Int {
        didSet {
            guard basePort != oldValue else { return }
            UserDefaults.standard.set(basePort, forKey: Keys.basePort)
            notify()
        }
    }

    /// The actual port the server is currently bound to (may differ from `basePort` on conflict).
    /// Set by `MCPServer` after a successful bind; unset when stopped.
    private(set) var actualPort: Int?

    /// Whatever the server most recently reported as its status string ("running", or an error).
    private(set) var statusMessage: String = "Stopped"

    /// Bearer token. Auto-generated on first enable; nil if missing.
    var token: String? {
        get { (try? Self.loadToken())?.nilIfEmpty }
    }

    /// Bumped whenever a setting that requires a server restart changes.
    private(set) var revision: Int = 0

    private init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.basePort) == nil {
            defaults.set(7711, forKey: Keys.basePort)
        }
        self.enabled = defaults.bool(forKey: Keys.enabled)
        self.bindAll = defaults.bool(forKey: Keys.bindAll)
        self.basePort = max(1024, defaults.integer(forKey: Keys.basePort))
    }

    func setActualPort(_ port: Int?, status: String) {
        actualPort = port
        statusMessage = status
    }

    @discardableResult
    func regenerateToken() throws -> String {
        let token = try Self.regenerateToken()
        notify()
        return token
    }

    private func notify() {
        revision &+= 1
    }

    private enum Keys {
        static let enabled = "mcp.enabled"
        static let bindAll = "mcp.bindAll"
        static let basePort = "mcp.basePort"
    }

    // MARK: - Keychain

    private static let service = "com.rxlab.film-workflow"
    private static let tokenAccount = "mcpToken"

    static func loadToken() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }
        return value
    }

    @discardableResult
    static func regenerateToken() throws -> String {
        let token = generateToken()
        try saveToken(token)
        return token
    }

    private static func saveToken(_ value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: tokenAccount
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw KeychainError.unexpectedStatus(updateStatus)
        }
    }

    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if result != errSecSuccess {
            // Fallback to UUIDs concatenated.
            return (UUID().uuidString + UUID().uuidString)
                .replacingOccurrences(of: "-", with: "")
                .lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
