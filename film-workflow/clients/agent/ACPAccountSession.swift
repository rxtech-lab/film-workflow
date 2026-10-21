#if os(macOS)
import Foundation
import RxAgentSDK
import RxAgentManagement

nonisolated struct ACPAccountMethod: Identifiable, Sendable {
    let id: String
    let name: String
    let description: String?
    let type: String
    let terminalCommand: String?
    let arguments: [String]
    let environment: [String: String]
}

nonisolated struct ACPSupportedModel: Identifiable, Sendable {
    let id: String
    let name: String
    let detail: String?
    let group: String?
}

/// A short-lived ACP connection used by account and model discovery sheets.
actor ACPAccountSession {
    private var process: ManagedProcess?
    private var connection: JSONRPCConnection?
    private var canSignOut = false

    func initialize(client: ManagedACPClient) async throws -> (methods: [ACPAccountMethod], logout: Bool) {
        await close()
        let environment = await ShellEnvironment.shared.environment()
        let executable = client.command.hasPrefix("/") ? client.command : "/usr/bin/env"
        let args = client.command.hasPrefix("/") ? client.arguments : [client.command] + client.arguments
        let process = try ManagedProcess.launch(executable: executable, arguments: args,
            environment: environment, workingDirectory: NSHomeDirectory())
        self.process = process
        let connection = JSONRPCConnection(process: process)
        self.connection = connection
        await connection.start()
        do {
            let result = try await request("initialize", params: .object([
                "protocolVersion": .number(1),
                "clientInfo": .object(["name": .string("RxFilmStudio"), "version": .string("1")]),
                "clientCapabilities": .object([:])
            ]))
            canSignOut = result["agentCapabilities"]?["auth"]?["logout"]?.objectValue != nil
            let methods = try (result["authMethods"]?.arrayValue ?? []).compactMap { value -> ACPAccountMethod? in
                guard let id = value["id"]?.stringValue else { return nil }
                let terminal = value["_meta"]?["terminal-auth"]
                let type = terminal?.objectValue != nil ? "terminal" : value["type"]?.stringValue ?? "agent"
                let details = terminal?.objectValue != nil ? terminal : value
                let method = ACPAccountMethod(id: id, name: value["name"]?.stringValue ?? id,
                    description: value["description"]?.stringValue, type: type,
                    terminalCommand: details?["command"]?.stringValue,
                    arguments: details?["args"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                    environment: details?["env"]?.objectValue?.compactMapValues(\.stringValue) ?? [:])
                return try Self.resolvedAccountMethod(method, client: client)
            }
            return (methods, canSignOut)
        } catch { await close(); throw error }
    }

    /// OpenCode V2 advertises terminal instructions without terminal-auth metadata.
    /// Its ACP authenticate acknowledgement does not establish an account session.
    nonisolated static func resolvedAccountMethod(_ method: ACPAccountMethod, client: ManagedACPClient) throws -> ACPAccountMethod {
        guard client.registryID == "opencode-v2", method.id == "opencode-login",
              method.type == "agent" else { return method }
        guard let directory = client.managedDirectory else {
            throw AgentManagementError.invalid("OpenCode sign-in requires its installed runtime. Reinstall this client and try again.")
        }
        let binary = URL(fileURLWithPath: directory).appendingPathComponent("opencode").path
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw AgentManagementError.invalid("The installed OpenCode executable is missing. Reinstall this client and try again.")
        }
        return ACPAccountMethod(id: method.id, name: method.name,
            description: "Connect your OpenCode account in Terminal and your browser, then refresh models.",
            type: "terminal", terminalCommand: binary, arguments: ["auth", "login", "opencode"], environment: [:])
    }

    /// Uses the same initialize + session/new discovery flow as RxCode.
    func supportedModels(client: ManagedACPClient) async throws -> [ACPSupportedModel] {
        do {
            _ = try await initialize(client: client)
            let result = try await request("session/new", params: .object([
                "cwd": .string(NSHomeDirectory()), "mcpServers": .array([])
            ]))
            let models = Self.parseModels(result)
            await close()
            return models
        } catch { await close(); throw error }
    }

    nonisolated static func parseModels(_ result: JSONValue) -> [ACPSupportedModel] {
        var models: [ACPSupportedModel] = []
        for option in result["configOptions"]?.arrayValue ?? [] {
            guard option["category"]?.stringValue == "model",
                  option["type"]?.stringValue == "select" else { continue }
            for entry in option["options"]?.arrayValue ?? [] {
                let group = entry["name"]?.stringValue ?? entry["group"]?.stringValue
                for value in entry["options"]?.arrayValue ?? [entry] {
                    guard let id = value["value"]?.stringValue, !id.isEmpty else { continue }
                    models.append(ACPSupportedModel(id: id,
                        name: value["name"]?.stringValue ?? id,
                        detail: value["description"]?.stringValue,
                        group: entry["options"] == nil ? nil : group))
                }
            }
        }
        if models.isEmpty {
            for value in result["models"]?["availableModels"]?.arrayValue ?? [] {
                guard let id = value["modelId"]?.stringValue, !id.isEmpty else { continue }
                models.append(ACPSupportedModel(id: id, name: value["name"]?.stringValue ?? id,
                    detail: value["description"]?.stringValue, group: nil))
            }
        }
        var seen = Set<String>()
        return models.filter { seen.insert($0.id).inserted }
    }

    func authenticate(method: String) async throws {
        _ = try await request("authenticate", params: .object(["methodId": .string(method)]), timeout: .seconds(300))
    }

    func signOut() async throws {
        guard canSignOut else { throw AgentManagementError.invalid("This client does not advertise ACP sign-out. Manage its account in the provider’s own CLI.") }
        _ = try await request("logout", params: .object([:]))
    }

    private func request(_ method: String, params: JSONValue, timeout: Duration = .seconds(30)) async throws -> JSONValue {
        guard let connection else { throw AgentManagementError.invalid("The account connection is closed.") }
        return try await withThrowingTaskGroup(of: JSONValue.self) { group in
            group.addTask { try await connection.request(method, params: params) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw AgentManagementError.invalid("The client did not finish the account request in time.")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    func close() async {
        await connection?.close()
        await process?.terminate()
        connection = nil; process = nil; canSignOut = false
    }
}
#endif
