#if os(macOS)
import XCTest
import RxAgentManagement
@testable import film_workflow

@MainActor
final class ACPClientSelectionTests: XCTestCase {
    func testInstalledClientsLoadAndRepairMissingDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "acp-selection-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-client", forKey: "agent.acp.selected")
        let service = AgentManagementService(root: root)
        let disabled = ManagedACPClient(name: "Disabled", command: "/bin/false", enabled: false)
        let installed = ManagedACPClient(name: "OpenCode V2", command: "/usr/bin/true")
        try await service.save([disabled, installed])
        let store = AgentManagementStore(service: service, defaults: defaults)
        await store.load()
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.clients.map(\.name), ["Disabled", "OpenCode V2"])
        XCTAssertEqual(store.selected?.id, installed.id)
        XCTAssertEqual(defaults.string(forKey: "agent.acp.selected"), installed.id)
    }

    func testClientSelectionIsPerThreadAndClearsOnlyPreviousACPModel() throws {
        let first = ManagedACPClient(name: "First", command: "/usr/bin/true")
        let second = ManagedACPClient(name: "Second", command: "/bin/true", arguments: ["--acp"])
        let thread = film_workflow.AgentThread()
        let other = film_workflow.AgentThread()
        try thread.selectACPClient(first)
        thread.setModelOverride("previous-client-model", for: .acp)
        thread.setModelOverride("codex-model", for: .codex)
        try thread.selectACPClient(second)
        XCTAssertEqual(thread.backendOverride, .acp)
        XCTAssertEqual(thread.configuredACPClient, second)
        XCTAssertNil(thread.modelOverride(for: .acp))
        XCTAssertEqual(thread.modelOverride(for: .codex), "codex-model")
        XCTAssertNil(other.configuredACPClient)
    }

    func testModelSelectionSurvivesReselectingClientAndDefaultClearsIt() throws {
        let client = ManagedACPClient(name: "Fixture", command: "/usr/bin/true")
        let thread = film_workflow.AgentThread()
        try thread.selectACPClient(client)
        thread.setModelOverride("provider/model", for: .acp)
        try thread.selectACPClient(client)
        XCTAssertEqual(thread.modelOverride(for: .acp), "provider/model")
        thread.setModelOverride(nil, for: .acp)
        XCTAssertNil(thread.modelOverride(for: .acp))
        XCTAssertEqual(thread.configuredACPClient?.id, client.id)
    }

    func testDisabledClientsCannotBeSelected() throws {
        let thread = film_workflow.AgentThread()
        try thread.selectACPClient(ManagedACPClient(name: "Disabled", command: "/bin/false", enabled: false))
        XCTAssertNil(thread.configuredACPClient)
        XCTAssertNil(thread.backendOverride)
    }
}
#endif
