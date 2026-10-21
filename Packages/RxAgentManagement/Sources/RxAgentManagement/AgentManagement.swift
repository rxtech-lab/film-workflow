#if os(macOS)
import Foundation
import AppKit
import CryptoKit

public enum AgentManagementError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public struct ManagedACPClient: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var command: String
    public var arguments: [String]
    public var enabled: Bool
    public var registryID: String?
    public var version: String?
    public var managedDirectory: String?

    public init(id: String = UUID().uuidString, name: String, command: String,
                arguments: [String] = [], enabled: Bool = true, registryID: String? = nil,
                version: String? = nil, managedDirectory: String? = nil) {
        self.id = id; self.name = name; self.command = command; self.arguments = arguments
        self.enabled = enabled; self.registryID = registryID; self.version = version
        self.managedDirectory = managedDirectory
    }
}

public struct AgentRegistry: Decodable, Sendable {
    public var agents: [AgentRegistryEntry]
}

public struct AgentRegistryEntry: Decodable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var distribution: Distribution
    public struct Distribution: Decodable, Sendable {
        public var npx: PackageDistribution?
        public var uvx: PackageDistribution?
        public var binary: [String: BinaryDistribution]?
    }
    public struct PackageDistribution: Decodable, Sendable {
        public var package: String
        public var args: [String]?
        public var env: [String: String]?
    }
    public struct BinaryDistribution: Decodable, Sendable {
        public var archive: String
        public var cmd: String
        public var sha256: String?
        public var args: [String]?
        public var env: [String: String]?
    }
    public var canInstall: Bool {
        distribution.binary?[Self.platform] != nil || distribution.npx != nil || distribution.uvx != nil
    }
    public static var platform: String {
        #if arch(arm64)
        "darwin-aarch64"
        #else
        "darwin-x86_64"
        #endif
    }
}

/// Host-scoped storage: clients and downloaded tools never overlap another app's directory.
public actor AgentManagementService {
    public static let registryURL = URL(string: "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json")!
    public let root: URL
    private let session: URLSession

    public init(root: URL, session: URLSession = .shared) {
        self.root = root; self.session = session
    }

    public nonisolated func runtimePath(_ provider: CLIAccountProvider) -> String {
        root.appendingPathComponent("runtimes/\(provider.rawValue)/node_modules/.bin/\(provider.rawValue)").path
    }

    public func installRuntime(_ provider: CLIAccountProvider, path: String) async throws -> String {
        let directory = root.appendingPathComponent("runtimes/\(provider.rawValue)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let package = provider == .codex ? "@openai/codex" : "@anthropic-ai/claude-code"
        _ = try await AgentCommand.run("/usr/bin/env", arguments: ["npm", "install", "--prefix", directory.path, "--", package], path: path, timeout: 300)
        let binary = runtimePath(provider)
        guard FileManager.default.isExecutableFile(atPath: binary) else {
            throw AgentManagementError.invalid("The runtime was downloaded but its executable is missing.")
        }
        return binary
    }

    public func load() throws -> [ManagedACPClient] {
        let file = root.appendingPathComponent("clients.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([ManagedACPClient].self, from: Data(contentsOf: file))
    }

    public func save(_ clients: [ManagedACPClient]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(clients).write(to: root.appendingPathComponent("clients.json"), options: .atomic)
    }

    public func registry() async throws -> [AgentRegistryEntry] {
        let (data, response) = try await session.data(from: Self.registryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw AgentManagementError.invalid("The ACP registry could not be loaded. Try again.")
        }
        return try JSONDecoder().decode(AgentRegistry.self, from: data).agents
    }

    public static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..",
              value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw AgentManagementError.invalid("Invalid client ID or version.")
        }
    }

    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Pins package releases; registry URLs/options cannot become package-manager switches.
    public static func pinnedPackage(_ package: String, version: String, npm: Bool) throws -> String {
        try validateComponent(version)
        guard version.first?.isNumber == true else { throw AgentManagementError.invalid("Invalid version.") }
        var name = package
        if npm {
            if let at = name.dropFirst().lastIndex(of: "@") { name = String(name[..<at]) }
            guard name.range(of: #"^(?:@[A-Za-z0-9._-]+/)?[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
                throw AgentManagementError.invalid("Invalid npm package.")
            }
            return name + "@" + version
        }
        name = name.components(separatedBy: "==")[0].components(separatedBy: "@")[0]
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw AgentManagementError.invalid("Invalid Python package.")
        }
        return name + "==" + version
    }

    public func install(_ entry: AgentRegistryEntry, path: String) async throws -> ManagedACPClient {
        try Self.validateComponent(entry.id)
        try Self.validateComponent(entry.version)
        // Unique directory keeps a failed update from damaging the installed release.
        let directory = root.appendingPathComponent("tools/\(entry.id)/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: directory) } }
        let command: String
        let args: [String]
        let env: [String: String]
        if let binary = entry.distribution.binary?[AgentRegistryEntry.platform] {
            guard let url = URL(string: binary.archive), url.scheme == "https" else {
                throw AgentManagementError.invalid("Client downloads must use HTTPS.")
            }
            let (download, response) = try await session.download(from: url)
            defer { try? FileManager.default.removeItem(at: download) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw AgentManagementError.invalid("Client download failed.")
            }
            if let expected = binary.sha256 {
                let digest = SHA256.hash(data: try Data(contentsOf: download)).map { String(format: "%02x", $0) }.joined()
                guard digest == expected.lowercased() else { throw AgentManagementError.invalid("Download checksum mismatch.") }
            }
            let zip = url.path.hasSuffix(".zip")
            guard zip || url.path.hasSuffix(".tar.gz") || url.path.hasSuffix(".tgz") else {
                throw AgentManagementError.invalid("Unsupported client archive.")
            }
            let listing = try await AgentCommand.run(zip ? "/usr/bin/unzip" : "/usr/bin/tar",
                arguments: zip ? ["-Z1", download.path] : ["-tzf", download.path], path: path)
            for item in listing.output.split(separator: "\n") {
                guard !item.hasPrefix("/"), !item.split(separator: "/").contains("..") else {
                    throw AgentManagementError.invalid("Unsafe archive path.")
                }
            }
            _ = try await AgentCommand.run(zip ? "/usr/bin/unzip" : "/usr/bin/tar",
                arguments: zip ? ["-q", download.path, "-d", directory.path] : ["-xzf", download.path, "-C", directory.path], path: path)
            let executable = directory.appendingPathComponent(binary.cmd).resolvingSymlinksInPath()
            guard executable.path.hasPrefix(directory.resolvingSymlinksInPath().path + "/"),
                  FileManager.default.fileExists(atPath: executable.path) else {
                throw AgentManagementError.invalid("The archive does not contain a valid executable.")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            command = executable.path; args = binary.args ?? []; env = binary.env ?? [:]
        } else if let npm = entry.distribution.npx {
            let package = try Self.pinnedPackage(npm.package, version: entry.version, npm: true)
            _ = try await AgentCommand.run("/usr/bin/env", arguments: ["npm", "install", "--prefix", directory.path, "--", package], path: path, timeout: 300)
            command = "/usr/bin/env"
            args = ["npm", "exec", "--offline", "--prefix", directory.path, "--", package] + (npm.args ?? [])
            env = npm.env ?? [:]
        } else if let uv = entry.distribution.uvx {
            let package = try Self.pinnedPackage(uv.package, version: entry.version, npm: false)
            _ = try await AgentCommand.run("/usr/bin/env", arguments: ["uv", "tool", "install", "--", package], path: path,
                environment: ["UV_TOOL_DIR": directory.path, "UV_TOOL_BIN_DIR": directory.appendingPathComponent("bin").path], timeout: 300)
            let binDirectory = directory.appendingPathComponent("bin")
            let tools = try FileManager.default.contentsOfDirectory(at: binDirectory, includingPropertiesForKeys: nil)
                .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
            guard tools.count == 1, let tool = tools.first else {
                throw AgentManagementError.invalid("This Python package needs a custom executable configuration.")
            }
            command = tool.path; args = uv.args ?? []; env = uv.env ?? [:]
        } else { throw AgentManagementError.invalid("No compatible macOS distribution.") }
        let script = directory.appendingPathComponent("launch")
        let launch = "#!/bin/zsh\nexec /usr/bin/env " + env.sorted(by: { $0.key < $1.key }).map { Self.quote($0.key + "=" + $0.value) }.joined(separator: " ") + " " + ([command] + args).map(Self.quote).joined(separator: " ") + " \"$@\"\n"
        try launch.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        succeeded = true
        return ManagedACPClient(name: entry.name, command: script.path, registryID: entry.id,
            version: entry.version, managedDirectory: directory.path)
    }

    public func removeFiles(for client: ManagedACPClient, includingPreviousVersions: Bool = false) throws {
        guard let managed = client.managedDirectory else { return }
        let directory = URL(fileURLWithPath: managed).resolvingSymlinksInPath()
        guard directory.path.hasPrefix(root.appendingPathComponent("tools").resolvingSymlinksInPath().path + "/") else {
            throw AgentManagementError.invalid("The client directory is outside managed storage.")
        }
        var removal = directory
        if includingPreviousVersions, let registryID = client.registryID {
            try Self.validateComponent(registryID)
            let releases = root.appendingPathComponent("tools").appendingPathComponent(registryID).resolvingSymlinksInPath()
            guard directory.path.hasPrefix(releases.path + "/") else {
                throw AgentManagementError.invalid("The client directory does not match its registry ID.")
            }
            removal = releases
        }
        if FileManager.default.fileExists(atPath: removal.path) { try FileManager.default.removeItem(at: removal) }
    }
}

/// Bounded process execution with output drained to disk, never a pipe that can fill.
public enum AgentCommand {
    public struct Result: Sendable { public let status: Int32; public let output: String }
    public static func run(_ command: String, arguments: [String], path: String,
                           environment: [String: String] = [:], timeout: TimeInterval = 30,
                           allowFailure: Bool = false) async throws -> Result {
        let task = Task.detached {
            let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: output.path, contents: nil)
            defer { try? FileManager.default.removeItem(at: output) }
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command); process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle; process.standardError = handle
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = path
            env.merge(environment, uniquingKeysWith: { _, new in new })
            process.environment = env
            try process.run()
            defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                if Task.isCancelled || Date() > deadline {
                    process.terminate()
                    try await Task.sleep(for: .milliseconds(200))
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw AgentManagementError.invalid("The command timed out or was cancelled.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            let reader = try FileHandle(forReadingFrom: output)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 64 * 1024) ?? Data()
            let text = String(decoding: data, as: UTF8.self)
            guard allowFailure || process.terminationStatus == 0 else {
                throw AgentManagementError.invalid("The command failed (exit \(process.terminationStatus)). Check the tool installation and try again.")
            }
            return Result(status: process.terminationStatus, output: text)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

public enum CLIAccountProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude
    public var id: String { rawValue }
    public var name: String { self == .codex ? "GPT / Codex" : "Claude Code" }
    public var statusArguments: [String] { self == .codex ? ["login", "status"] : ["auth", "status"] }
    public var loginArguments: [String] { self == .codex ? ["login"] : ["auth", "login"] }
    public var logoutArguments: [String] { self == .codex ? ["logout"] : ["auth", "logout"] }

    public func status(binary: String, path: String) async throws -> String {
        let result = try await AgentCommand.run(binary, arguments: statusArguments, path: path, allowFailure: true)
        if self == .claude, let data = result.output.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let loggedIn = json["loggedIn"] as? Bool {
            return loggedIn ? ((json["email"] as? String).map { "Signed in as \($0)" } ?? "Signed in") : "Signed out"
        }
        if result.status == 0 { return "Signed in" }
        if result.status == 1 { return "Signed out" }
        throw AgentManagementError.invalid("Account status could not be checked (exit \(result.status)).")
    }

    /// CLI owns OAuth callbacks, credentials and browser interaction. No tokens enter the host app.
    @MainActor public func openSignIn(binary: String, path: String) throws {
        try AgentTerminalAction.open(command: binary, arguments: loginArguments, path: path)
    }
}

/// Opens an explicitly requested interactive account action with safely quoted arguments.
public enum AgentTerminalAction {
    @MainActor public static func open(command: String, arguments: [String], environment: [String: String] = [:], path: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agent-login-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("Account.command")
        let line = (["/usr/bin/env"] + environment.sorted(by: { $0.key < $1.key }).map { $0.key + "=" + $0.value }
            + [command] + arguments).map(AgentManagementService.quote).joined(separator: " ")
        try ("#!/bin/zsh\nexport PATH=\(AgentManagementService.quote(path))\n\(line)\nresult=$?\n/bin/rm -f -- \(AgentManagementService.quote(script.path))\n/bin/rmdir -- \(AgentManagementService.quote(directory.path))\nexit $result\n").write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw AgentManagementError.invalid("Could not open Terminal for the account action.") }
    }
}
#endif
