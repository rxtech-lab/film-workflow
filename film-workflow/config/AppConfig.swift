import Foundation
import Security

enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "No API key found in Keychain."
        case .duplicateItem:
            return "API key already exists in Keychain."
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode API key."
        }
    }
}

struct AppConfig: Codable {
    var googleAIKey: String
    var azureSpeechKey: String
    var azureSpeechEndpoint: String

    private static let service = "com.rxlab.film-workflow"
    private static let googleAccount = "googleAIKey"
    private static let azureKeyAccount = "azureSpeechKey"
    private static let azureEndpointAccount = "azureSpeechEndpoint"

    static func loadFromKeychain() throws -> AppConfig {
        AppConfig(
            googleAIKey: (try? loadString(account: googleAccount)) ?? "",
            azureSpeechKey: (try? loadString(account: azureKeyAccount)) ?? "",
            azureSpeechEndpoint: (try? loadString(account: azureEndpointAccount)) ?? ""
        )
    }

    func saveToKeychain() throws {
        try Self.saveString(googleAIKey, account: Self.googleAccount)
        try Self.saveString(azureSpeechKey, account: Self.azureKeyAccount)
        try Self.saveString(azureSpeechEndpoint, account: Self.azureEndpointAccount)
    }

    static func deleteFromKeychain() throws {
        try deleteString(account: googleAccount)
        try deleteString(account: azureKeyAccount)
        try deleteString(account: azureEndpointAccount)
    }

    // MARK: - Keychain helpers

    private static func loadString(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw KeychainError.itemNotFound
            }
            throw KeychainError.unexpectedStatus(status)
        }

        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw KeychainError.encodingFailed
        }

        return value
    }

    private static func saveString(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

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

    private static func deleteString(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
