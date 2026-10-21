#if os(macOS)
import Foundation
import Observation
import RxAgentSDK
import RxAgentManagement

@MainActor @Observable
final class AgentManagementStore {
    static let shared = AgentManagementStore()
    let service: AgentManagementService
    private let defaults: UserDefaults
    var clients: [ManagedACPClient] = []
    var loadError: String?
    var selectedID: String {
        didSet { defaults.set(selectedID, forKey: "agent.acp.selected") }
    }
    var selected: ManagedACPClient? { clients.first { $0.id == selectedID && $0.enabled } }
    init(service: AgentManagementService? = nil, defaults: UserDefaults = .standard) {
        self.service = service ?? AgentManagementService(root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("RxFilm/agents"))
        self.defaults = defaults
        selectedID = defaults.string(forKey: "agent.acp.selected") ?? ""
    }
    func load() async {
        do {
            clients = try await service.load()
            if !clients.contains(where: { $0.id == selectedID && $0.enabled }) {
                selectedID = clients.first(where: \.enabled)?.id ?? ""
            }
            loadError = nil
        }
        catch { loadError = error.localizedDescription }
    }
    func save(_ client: ManagedACPClient) async throws {
        var updated = clients
        if let index = updated.firstIndex(where: { $0.id == client.id }) { updated[index] = client }
        else { updated.append(client) }
        try await service.save(updated)
        clients = updated
        if selectedID.isEmpty { selectedID = client.id }
    }
    func remove(_ client: ManagedACPClient) async throws {
        // Persist removal before deleting downloads, so a failure never leaves a dangling launch path.
        let updated = clients.filter { $0.id != client.id }
        try await service.save(updated)
        clients = updated
        if selectedID == client.id { selectedID = updated.first(where: \.enabled)?.id ?? "" }
        try await service.removeFiles(for: client, includingPreviousVersions: true)
    }
}
#endif
