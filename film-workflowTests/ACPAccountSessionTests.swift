#if os(macOS)
import XCTest
import RxAgentManagement
import RxAgentSDK
@testable import film_workflow

final class ACPAccountSessionTests: XCTestCase {
    private func fixture(logout: Bool) throws -> (ManagedACPClient, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("agent.py")
        let source = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            method = request.get('method')
            if method == 'initialize':
                result = {
                    'authMethods': [
                        {'id': 'browser', 'name': 'Browser account'},
                        {'id': 'terminal', 'name': 'Terminal account', '_meta': {'terminal-auth': {'command': 'example-agent', 'args': ['auth', 'login'], 'env': {'EXAMPLE': '1'}}}},
                        {'id': 'key', 'name': 'API key', 'type': 'env_var', 'vars': [{'name': 'EXAMPLE_KEY'}]}
                    ],
                    'agentCapabilities': {'auth': {'logout': {}}} if \(logout ? "True" : "False") else {}
                }
            elif method == 'session/new':
                result = {'sessionId': 'probe', 'models': {'availableModels': [{'modelId': 'fixture-model', 'name': 'Fixture Model'}]}}
            else:
                result = {}
            print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        return (ManagedACPClient(name: "Fixture", command: "/usr/bin/python3", arguments: [script.path]), root)
    }

    func testDiscoversAdvertisedMethodsAndSignsInAndOut() async throws {
        let (client, root) = try fixture(logout: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ACPAccountSession()
        do {
            let info = try await session.initialize(client: client)
            XCTAssertTrue(info.logout)
            XCTAssertEqual(info.methods.map(\.type), ["agent", "terminal", "env_var"])
            XCTAssertEqual(info.methods[1].terminalCommand, "example-agent")
            XCTAssertEqual(info.methods[1].arguments, ["auth", "login"])
            XCTAssertEqual(info.methods[1].environment, ["EXAMPLE": "1"])
            try await session.authenticate(method: "browser")
            try await session.signOut()
            await session.close()
        } catch { await session.close(); throw error }
    }

    func testRejectsLogoutWhenNotAdvertised() async throws {
        let (client, root) = try fixture(logout: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ACPAccountSession()
        do {
            let info = try await session.initialize(client: client)
            XCTAssertFalse(info.logout)
            do { try await session.signOut(); XCTFail("Must not call unsupported logout") }
            catch { XCTAssertTrue(error.localizedDescription.contains("does not advertise")) }
            await session.close()
        } catch { await session.close(); throw error }
    }

    func testDiscoversModelsAndClosesProbe() async throws {
        let (client, root) = try fixture(logout: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ACPAccountSession()
        let models = try await session.supportedModels(client: client)
        XCTAssertEqual(models.map(\.id), ["fixture-model"])
        XCTAssertEqual(models.first?.name, "Fixture Model")
        do { try await session.authenticate(method: "browser"); XCTFail("Probe must close") }
        catch { XCTAssertTrue(error.localizedDescription.contains("closed")) }
    }

    func testParsesGroupedModelsAndIgnoresOtherSelectors() throws {
        let json = #"{"configOptions":[{"category":"mode","type":"select","options":[{"value":"code"}]},{"category":"model","type":"select","options":[{"group":"go","name":"OpenCode Go","options":[{"value":"go/model","name":"Model","description":"Included"},{"name":"Invalid"}]},{"value":"direct","name":"Direct"},{"value":"direct"}]}]}"#
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let models = ACPAccountSession.parseModels(result)
        XCTAssertEqual(models.map(\.id), ["go/model", "direct"])
        XCTAssertEqual(models.first?.group, "OpenCode Go")
        XCTAssertEqual(models.first?.detail, "Included")
        XCTAssertNil(models.last?.group)
        XCTAssertTrue(ACPAccountSession.parseModels(.object([:])).isEmpty)
    }

    func testOpenCodeLoginUsesInstalledBinaryInsteadOfACPAcknowledgement() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("opencode")
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: URL(fileURLWithPath: "/usr/bin/true"))
        let client = ManagedACPClient(name: "Renamed client", command: root.appendingPathComponent("launch").path,
            registryID: "opencode-v2", managedDirectory: root.path)
        let method = ACPAccountMethod(id: "opencode-login", name: "Login", description: nil,
            type: "agent", terminalCommand: nil, arguments: [], environment: [:])
        let resolved = try ACPAccountSession.resolvedAccountMethod(method, client: client)
        XCTAssertEqual(resolved.type, "terminal")
        XCTAssertEqual(resolved.terminalCommand, binary.path)
        XCTAssertEqual(resolved.arguments, ["auth", "login", "opencode"])
        let other = ManagedACPClient(name: "OpenCode V2", command: "/usr/bin/true")
        XCTAssertEqual(try ACPAccountSession.resolvedAccountMethod(method, client: other).type, "agent")
        let missing = ManagedACPClient(name: "Missing", command: "/usr/bin/true", registryID: "opencode-v2")
        XCTAssertThrowsError(try ACPAccountSession.resolvedAccountMethod(method, client: missing))
    }

    func testRejectsRequestsAfterClosing() async throws {
        let session = ACPAccountSession()
        await session.close()
        do { try await session.authenticate(method: "browser"); XCTFail("Closed session must reject requests") }
        catch { XCTAssertTrue(error.localizedDescription.contains("closed")) }
    }
}
#endif
