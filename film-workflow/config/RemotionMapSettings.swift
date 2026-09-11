import CryptoKit
import Foundation
import RxRemotion
import Security

@MainActor
enum RemotionMapSettings {
    private static let service = "com.rxlab.film-workflow.remotion-maps"
    private(set) static var configuration: RemotionConfiguration = load()
    static var fingerprint: String {
        RemotionEngine.runtimeFingerprint + "-" + RemotionEngine(configuration: configuration).configurationFingerprint
    }
    private static func load() -> RemotionConfiguration {
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") { return .init() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "configuration", kSecReturnData as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let config = try? JSONDecoder().decode(RemotionConfiguration.self, from: data) else { return .init() }
        return config
    }
    static func save(_ config: RemotionConfiguration) throws {
        if let provider = config.openStreetMap {
            let candidate = provider.tileURL.replacingOccurrences(of: "{z}", with: "0")
                .replacingOccurrences(of: "{x}", with: "0").replacingOccurrences(of: "{y}", with: "0")
            guard let url = URL(string: candidate), url.scheme == "https", let host = url.host,
                  host != "tile.openstreetmap.org", !host.hasSuffix(".tile.openstreetmap.org"),
                  ["{z}", "{x}", "{y}"].allSatisfy(provider.tileURL.contains), provider.allowsExport,
                  !provider.attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0...22).contains(provider.minimumZoom), (provider.minimumZoom...22).contains(provider.maximumZoom) else {
                throw RemotionError.resource("Enter an HTTPS tile URL with {z}, {x}, and {y}, attribution, and confirm your provider permits exports. Public OpenStreetMap tiles cannot be used.")
            }
        }
        let data = try JSONEncoder().encode(config)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: "configuration"]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        configuration = config
        RemotionPreviewSessions.shared.configurationChanged()
    }
}
