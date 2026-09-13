import Foundation
import Security

nonisolated enum KeychainError: LocalizedError {
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

/// Settings that live in the Keychain.
///
/// Every AI capability except chat runs through the RxFilm subscription, so the
/// only credential kept here is the optional OpenAI-compatible endpoint that
/// adds an extra chat engine. The rest are model choices — not secrets, but
/// they were always stored alongside the keys and moving them would only
/// lose people's settings.
nonisolated struct AppConfig: Codable, Equatable, Sendable {
    /// OpenAI-compatible base URL for the optional chat engine. Empty means
    /// the engine is not offered.
    var openAIEndpoint: String = ""
    var openAIKey: String = ""
    /// Default chat model on the OpenAI-compatible endpoint.
    var openAIModel: String = ""
    /// Passed to `claude --model`. Empty means the CLI's own default.
    ///
    /// Separate from `openAIModel` because they name models in different
    /// namespaces — a `gpt-4o` configured for the endpoint used to be handed
    /// straight to the Claude CLI, which cannot run it.
    var claudeCodeModel: String = ""
    /// Passed to `codex --model`. Empty means the CLI's own default.
    var codexModel: String = ""
    /// Passed to Codex as `-c model_reasoning_effort=<x>`. Empty means the
    /// model's own default.
    ///
    /// No Claude Code twin: `claude --effort` exists, but nothing here sets it.
    var codexReasoningEffort: String = ""
    /// Subscription model ids, all from `GET /api/v1/models`.
    var subscriptionChatModel: String = ""
    var subscriptionImageModel: String = ""
    var subscriptionTranscriptionModel: String = ""
    /// Prefilled on new video projects. Empty means "ask the user".
    var subscriptionVideoModel: String = ""

    init() {}

    private static let service = "com.rxlab.film-workflow"
    private static let openAIEndpointAccount = "openAIEndpoint"
    private static let openAIKeyAccount = "openAIKey"
    private static let openAIModelAccount = "openAIModel"
    private static let claudeCodeModelAccount = "claudeCodeModel"
    private static let codexModelAccount = "codexModel"
    private static let codexReasoningEffortAccount = "codexReasoningEffort"
    private static let subscriptionChatModelAccount = "subscriptionChatModel"
    private static let subscriptionImageModelAccount = "subscriptionImageModel"
    private static let subscriptionTranscriptionModelAccount = "subscriptionTranscriptionModel"
    private static let subscriptionVideoModelAccount = "subscriptionVideoModel"

    /// Keychain items from the bring-your-own-key era. Nothing reads them any
    /// more; `purgeLegacyKeys` deletes them so no secret outlives its use.
    private static let legacyAccounts = [
        "googleAIKey",
        "azureSpeechKey",
        "azureSpeechEndpoint",
        "defaultImageModel",
        "defaultVideoModel",
        "openAITranscriptionModel",
        "geminiTranscriptionModel",
        "credentialMode",
    ]

    /// Whether the optional OpenAI-compatible chat engine can be offered.
    var hasOpenAICompatibleChat: Bool {
        !openAIEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIKey.trimmingCharacters(in: .whitespaces).isEmpty
            && !openAIModel.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Every field paired with the Keychain account that holds it, so no save
    /// path can drop one and a diffing save can name exactly what changed.
    private static let fields: [(keyPath: WritableKeyPath<AppConfig, String>, account: String)] = [
        (\.openAIEndpoint, openAIEndpointAccount),
        (\.openAIKey, openAIKeyAccount),
        (\.openAIModel, openAIModelAccount),
        (\.claudeCodeModel, claudeCodeModelAccount),
        (\.codexModel, codexModelAccount),
        (\.codexReasoningEffort, codexReasoningEffortAccount),
        (\.subscriptionChatModel, subscriptionChatModelAccount),
        (\.subscriptionImageModel, subscriptionImageModelAccount),
        (\.subscriptionTranscriptionModel, subscriptionTranscriptionModelAccount),
        (\.subscriptionVideoModel, subscriptionVideoModelAccount),
    ]

    static func loadFromKeychain() throws -> AppConfig {
        var config = AppConfig()
        for field in fields {
            config[keyPath: field.keyPath] = (try? loadString(account: field.account)) ?? ""
        }
        return config
    }

    func saveToKeychain() throws {
        for field in Self.fields {
            try Self.saveString(self[keyPath: field.keyPath], account: field.account)
        }
    }

    /// Writes only the fields that differ from `old`.
    ///
    /// The settings panes autosave as you type and two of them edit the same
    /// accounts, so a whole-record write would push one pane's stale copy of a
    /// field the other pane just changed. Writing only the edits keeps each
    /// pane to the fields it actually touched.
    func saveChanges(since old: AppConfig) throws {
        for field in Self.fields where self[keyPath: field.keyPath] != old[keyPath: field.keyPath] {
            try Self.saveString(self[keyPath: field.keyPath], account: field.account)
        }
    }

    /// Removes provider keys saved by versions that supported bring-your-own-key.
    ///
    /// Runs once per install (tracked in UserDefaults) — a Keychain delete is
    /// cheap, but not free of access prompts, so it is not repeated on every
    /// launch. Missing items are not an error.
    static func purgeLegacyKeys() {
        let flag = "config.legacyKeysPurged.v1"
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        for account in legacyAccounts {
            try? deleteString(account: account)
        }
        UserDefaults.standard.set(true, forKey: flag)
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
