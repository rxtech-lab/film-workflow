import Foundation
import Observation

struct SubscriptionUsageEntry: Codable, Identifiable, Sendable {
    let id: String
    let capability: String
    let feature: String
    let provider: String
    let model: String?
    let chargedPoints: Int
    let unitKind: String?
    let unitCount: Int?
    let createdAt: String
}

struct SubscriptionUsageGroup: Codable, Identifiable, Sendable {
    let capability: String
    let points: Int
    var id: String { capability }
}

private struct UsageHistoryResponse: Codable {
    let usage: [SubscriptionUsageEntry]
    let grouped: [SubscriptionUsageGroup]
    let currentPage: Int
    let pageCount: Int
}

@Observable
@MainActor
final class UsageHistoryStore {
    static let shared = UsageHistoryStore()

    private(set) var entries: [SubscriptionUsageEntry] = []
    private(set) var grouped: [SubscriptionUsageGroup] = []
    private(set) var currentPage = 1
    private(set) var pageCount = 1
    private(set) var isLoading = false
    private(set) var error: String?

    private init() {}

    func refresh(page: Int = 1) async {
        guard AuthManager.shared.isAuthenticated else {
            entries = []
            grouped = []
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let response: UsageHistoryResponse = try await BackendClient.shared.get(
                "api/billing/usage",
                query: [URLQueryItem(name: "page", value: String(page))]
            )
            entries = response.usage
            grouped = response.grouped
            currentPage = response.currentPage
            pageCount = response.pageCount
        } catch {
            self.error = error.localizedDescription
        }
    }
}
