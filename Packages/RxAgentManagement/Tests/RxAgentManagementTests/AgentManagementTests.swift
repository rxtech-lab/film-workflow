import XCTest
@testable import RxAgentManagement

final class AgentManagementTests: XCTestCase {
    func testPackagePinningAndValidation() throws {
        XCTAssertEqual(try AgentManagementService.pinnedPackage("@zed-industries/claude-agent-acp@latest", version: "1.2.3", npm: true), "@zed-industries/claude-agent-acp@1.2.3")
        XCTAssertEqual(try AgentManagementService.pinnedPackage("agent==0.1.0", version: "2.0.0", npm: false), "agent==2.0.0")
        for value in ["../outside", "", "--prefix", "https://example.com/tool"] {
            XCTAssertThrowsError(try AgentManagementService.pinnedPackage(value, version: "1.2.3", npm: true))
        }
        XCTAssertThrowsError(try AgentManagementService.validateComponent("../outside"))
    }

    func testRegistryDecodesUnknownFieldsAndDistributions() throws {
        let json = #"{"agents":[{"id":"test","name":"Test","version":"1.0.0","description":"Test agent","unknown":true,"distribution":{"npx":{"package":"agent@1.0.0","args":["--acp"]}}}]}"#
        let registry = try JSONDecoder().decode(AgentRegistry.self, from: Data(json.utf8))
        XCTAssertEqual(registry.agents.first?.distribution.npx?.args, ["--acp"])
        XCTAssertTrue(registry.agents[0].canInstall)
        XCTAssertThrowsError(try JSONDecoder().decode(AgentRegistry.self, from: Data(#"{"agents":[{"id":"incomplete"}]}"#.utf8)))
    }

    func testPersistenceAndExternalFileProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = AgentManagementService(root: root)
        let empty = try await service.load()
        XCTAssertTrue(empty.isEmpty)
        let client = ManagedACPClient(name: "Test", command: "/usr/bin/true")
        try await service.save([client])
        let loaded = try await service.load()
        XCTAssertEqual(loaded, [client])
        let outside = ManagedACPClient(name: "External", command: "/bin/sh", managedDirectory: "/bin")
        do { try await service.removeFiles(for: outside); XCTFail("Must reject external directory") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: "/bin/sh")) }
    }

    func testRemovalCanCleanPreviousVersionsWithoutTouchingOtherClients() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let first = root.appendingPathComponent("tools/test/first")
        let second = root.appendingPathComponent("tools/test/second")
        let other = root.appendingPathComponent("tools/other/first")
        for directory in [first, second, other] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        let service = AgentManagementService(root: root)
        let client = ManagedACPClient(name: "Test", command: second.path, registryID: "test", managedDirectory: second.path)
        try await service.removeFiles(for: client, includingPreviousVersions: true)
        XCTAssertFalse(fm.fileExists(atPath: first.path))
        XCTAssertFalse(fm.fileExists(atPath: second.path))
        XCTAssertTrue(fm.fileExists(atPath: other.path))
    }

    func testCommandDrainsLargeOutputAndReportsFailure() async throws {
        let output = try await AgentCommand.run("/usr/bin/seq", arguments: ["1", "50000"], path: "/usr/bin:/bin")
        XCTAssertEqual(output.status, 0)
        XCTAssertEqual(output.output.utf8.count, 64 * 1024)
        let failed = try await AgentCommand.run("/usr/bin/false", arguments: [], path: "/usr/bin:/bin", allowFailure: true)
        XCTAssertNotEqual(failed.status, 0)
    }

    func testCommandTimeout() async throws {
        do {
            _ = try await AgentCommand.run("/bin/sleep", arguments: ["10"], path: "/usr/bin:/bin", timeout: 0.1)
            XCTFail("Expected a bounded timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
    }

    func testShellQuoting() {
        XCTAssertEqual(AgentManagementService.quote("a'b $(touch /tmp/test)"), "'a'\\''b $(touch /tmp/test)'")
    }
}
