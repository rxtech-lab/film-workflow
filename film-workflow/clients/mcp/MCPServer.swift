import Foundation
import Network
import Observation
import SwiftData

enum MCPServerError: LocalizedError {
    case noPortAvailable(base: Int)
    case bindFailed(String)
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .noPortAvailable(let base):
            return "No free port found in [\(base), \(base + 9)]"
        case .bindFailed(let detail):
            return "MCP listener failed: \(detail)"
        case .notConfigured:
            return "MCP server is not configured."
        }
    }
}

/// Embedded MCP HTTP server. Single shared instance bootstrapped by the App.
///
/// Lifecycle: `bootstrap(container:)` is called once on launch — it observes
/// `MCPSettings` and starts/stops/restarts the listener as the user toggles the
/// settings UI. While running, it accepts incoming TCP connections, parses HTTP/1.1,
/// and routes `POST /mcp` to `MCPRouter.handle`.
@MainActor
@Observable
final class MCPServer {
    static let shared = MCPServer()

    private(set) var isRunning: Bool = false
    private(set) var lastError: String?
    private(set) var displayURL: String?

    /// Connection-handling queue. Static so we don't need to thread it through
    /// nonisolated closures.
    private static let queue = DispatchQueue(
        label: "com.rxlab.film-workflow.mcp",
        qos: .userInitiated
    )

    private var listener: NWListener?
    private var modelContainer: ModelContainer?
    private var lastObservedRevision: Int = -1
    private var pollTask: Task<Void, Never>?

    private init() {}

    func bootstrap(container: ModelContainer) {
        self.modelContainer = container

        pollTask?.cancel()
        let settings = MCPSettings.shared
        lastObservedRevision = settings.revision
        if settings.enabled {
            Task { await self.start() }
        }
        // Lightweight observation loop on the main actor.
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let s = MCPSettings.shared
                if s.revision != self.lastObservedRevision {
                    self.lastObservedRevision = s.revision
                    if s.enabled {
                        await self.restart()
                    } else {
                        await self.stop()
                    }
                }
            }
        }
    }

    func start() async {
        await stop()
        guard modelContainer != nil else {
            lastError = MCPServerError.notConfigured.localizedDescription
            MCPSettings.shared.setActualPort(nil, status: lastError ?? "Not configured")
            return
        }
        let settings = MCPSettings.shared
        do {
            let port = try findFreePort(starting: settings.basePort)
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = !settings.bindAll
            let listener = try NWListener(
                using: params,
                on: NWEndpoint.Port(integerLiteral: UInt16(port))
            )
            self.listener = listener

            listener.newConnectionHandler = { conn in
                Self.queue.async {
                    Self.accept(conn: conn)
                }
            }
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.lastError = nil
                        let displayHost = settings.bindAll ? Self.bestLocalIPv4() ?? "0.0.0.0" : "127.0.0.1"
                        self.displayURL = "http://\(displayHost):\(port)/mcp"
                        MCPSettings.shared.setActualPort(port, status: "Running")
                    case .failed(let err):
                        self.isRunning = false
                        self.lastError = err.localizedDescription
                        self.displayURL = nil
                        MCPSettings.shared.setActualPort(nil, status: "Failed: \(err.localizedDescription)")
                    case .cancelled:
                        self.isRunning = false
                        self.displayURL = nil
                        MCPSettings.shared.setActualPort(nil, status: "Stopped")
                    default:
                        break
                    }
                }
            }
            listener.start(queue: Self.queue)
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            MCPSettings.shared.setActualPort(nil, status: "Failed: \(error.localizedDescription)")
        }
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        isRunning = false
        displayURL = nil
        MCPSettings.shared.setActualPort(nil, status: "Stopped")
    }

    func restart() async {
        await stop()
        await start()
    }

    // MARK: - Connection handling (nonisolated)

    private nonisolated static func accept(conn: NWConnection) {
        let buffer = ConnectionBuffer()
        conn.start(queue: queue)
        receiveLoop(conn: conn, buffer: buffer)
    }

    private nonisolated static func receiveLoop(
        conn: NWConnection,
        buffer: ConnectionBuffer
    ) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            do {
                if let parsed = try MCPHTTP.parseRequest(buffer: buffer.snapshot()) {
                    let snapshot = buffer.snapshot()
                    let consumed = parsed.1
                    let requestData = snapshot.subdata(in: 0..<consumed)
                    Task { @MainActor in
                        await MCPServer.shared.respond(conn: conn, requestData: requestData)
                    }
                    return
                }
            } catch {
                let err = MCPHTTP.makeResponse(status: 400, contentType: "text/plain", body: Data("\(error)".utf8))
                conn.send(content: err, completion: .contentProcessed { _ in conn.cancel() })
                return
            }
            if error != nil || isComplete {
                conn.cancel()
                return
            }
            receiveLoop(conn: conn, buffer: buffer)
        }
    }

    fileprivate func respond(conn: NWConnection, requestData: Data) async {
        guard let modelContainer else {
            send(conn: conn, response: MCPHTTP.makeResponse(status: 500, contentType: "text/plain", body: Data("not configured".utf8)))
            return
        }
        let response: Data
        do {
            guard let (request, _) = try MCPHTTP.parseRequest(buffer: requestData) else {
                response = MCPHTTP.makeResponse(status: 400, contentType: "text/plain", body: Data("bad request".utf8))
                send(conn: conn, response: response); return
            }
            response = await MCPRouter.handle(
                request: request,
                container: modelContainer,
                settings: MCPSettings.shared
            )
        } catch {
            response = MCPHTTP.makeResponse(status: 400, contentType: "text/plain", body: Data("parse error".utf8))
        }
        send(conn: conn, response: response)
    }

    private func send(conn: NWConnection, response: Data) {
        conn.send(content: response, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Port probing

    private func findFreePort(starting base: Int) throws -> Int {
        for offset in 0..<10 {
            let candidate = base + offset
            if Self.isPortFree(candidate) { return candidate }
        }
        throw MCPServerError.noPortAvailable(base: base)
    }

    private static func isPortFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd == -1 { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY.bigEndian
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Pick the first non-loopback IPv4 we can find for display when bound to 0.0.0.0.
    static func bestLocalIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let head = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var ptr = head
        while true {
            let interface = ptr.pointee
            let family = interface.ifa_addr?.pointee.sa_family
            if family == sa_family_t(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("eth") {
                    var hostBuf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let saLen = socklen_t(interface.ifa_addr.pointee.sa_len)
                    if getnameinfo(
                        interface.ifa_addr,
                        saLen,
                        &hostBuf,
                        socklen_t(hostBuf.count),
                        nil, 0, NI_NUMERICHOST
                    ) == 0 {
                        let s = String(cString: hostBuf)
                        if !s.isEmpty, !s.hasPrefix("127.") {
                            return s
                        }
                    }
                }
            }
            if let next = interface.ifa_next {
                ptr = next
            } else {
                break
            }
        }
        return nil
    }
}

private final class ConnectionBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }
    func snapshot() -> Data {
        lock.lock(); defer { lock.unlock() }
        return data
    }
}
