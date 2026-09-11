import Foundation
@preconcurrency import Network

struct ResourceRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct ResourceResponse {
    var status = 200
    var type = "application/octet-stream"
    var data = Data()
    var file: URL?
    var headers: [String: String] = [:]
    static func json<T: Encodable>(_ value: T) throws -> Self {
        Self(type: "application/json", data: try JSONEncoder().encode(value))
    }
}

@MainActor
final class ResourceServer {
    private let listener: NWListener
    private var connections: [UUID: ResourceConnection] = [:]
    private var port: UInt16?
    private var failure: String?
    let token = UUID().uuidString
    var handle: ((ResourceRequest) async throws -> ResourceResponse)?
    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready: self?.port = self?.listener.port?.rawValue
                case .failed(let error): self?.failure = error.localizedDescription
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let id = UUID()
                let client = ResourceConnection(connection: connection) { [weak self] request in
                    guard let self, request.path.hasPrefix("/\(self.token)/") else {
                        return ResourceResponse(status: 404)
                    }
                    return try await self.handle?(request) ?? ResourceResponse(status: 404)
                } onClose: { [weak self] in self?.connections.removeValue(forKey: id) }
                self.connections[id] = client
                client.start()
            }
        }
        listener.start(queue: DispatchQueue(label: "app.rxlab.remotion.resources"))
    }
    func start() async throws -> URL {
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let port { return URL(string: "http://127.0.0.1:\(port)/\(token)/")! }
            if let failure { throw RemotionError.resource(failure) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RemotionError.resource("The native Remotion resource server did not start.")
    }
    func stop() {
        listener.cancel()
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll(); handle = nil
    }

    nonisolated static func containedFile(_ path: String, root: URL) throws -> URL {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(path).resolvingSymlinksInPath().standardizedFileURL
        guard file.path.hasPrefix(root.path + "/"),
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw RemotionError.resource("Resource is missing or outside the project: \(path)")
        }
        return file
    }
    static func mime(_ url: URL) -> String {
        let types = ["js":"text/javascript", "mjs":"text/javascript", "css":"text/css", "html":"text/html",
         "json":"application/json", "wasm":"application/wasm", "svg":"image/svg+xml", "png":"image/png",
         "jpg":"image/jpeg", "jpeg":"image/jpeg", "webp":"image/webp", "gif":"image/gif", "avif":"image/avif",
         "mp4":"video/mp4", "mov":"video/quicktime", "webm":"video/webm", "mp3":"audio/mpeg",
         "wav":"audio/wav", "aac":"audio/aac", "m4a":"audio/mp4", "woff":"font/woff", "woff2":"font/woff2"]
        return types[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }
    static func byteRange(_ header: String?, length: Int) throws -> Range<Int> {
        guard let header else { return 0..<length }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw RemotionError.resource("Invalid byte range") }
        let parts = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, length > 0 else { throw RemotionError.resource("Invalid byte range") }
        let start: Int, end: Int
        if parts[0].isEmpty {
            guard let suffix = Int(parts[1]), suffix > 0 else { throw RemotionError.resource("Invalid suffix range") }
            start = max(0, length - suffix); end = length
        } else {
            guard let first = Int(parts[0]), first >= 0 else { throw RemotionError.resource("Invalid byte range") }
            start = first
            if parts[1].isEmpty { end = length }
            else {
                guard let last = Int(parts[1]), last >= 0, last < Int.max else { throw RemotionError.resource("Invalid byte range") }
                end = min(length, last + 1)
            }
        }
        guard start < end, start < length else { throw RemotionError.resource("Unsatisfiable byte range") }
        return start..<end
    }
}

@MainActor
private final class ResourceConnection {
    let connection: NWConnection
    let handle: (ResourceRequest) async throws -> ResourceResponse
    let onClose: () -> Void
    var buffer = Data()
    var file: FileHandle?
    var remaining = 0
    var closed = false
    var task: Task<Void, Never>?
    init(connection: NWConnection, handle: @escaping (ResourceRequest) async throws -> ResourceResponse,
         onClose: @escaping () -> Void) {
        self.connection = connection; self.handle = handle; self.onClose = onClose
    }
    func start() { connection.start(queue: .global(qos: .userInitiated)); receive() }
    func close() {
        guard !closed else { return }; closed = true
        task?.cancel(); task = nil; try? file?.close(); file = nil
        connection.cancel(); onClose()
    }
    func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data) }
                guard self.buffer.count <= 32 * 1024 * 1024 else { self.close(); return }
                if let request = self.parse() {
                    self.buffer.removeAll()
                    self.task = Task { @MainActor in
                        do { try self.respond(try await self.handle(request), request: request) }
                        catch {
                            try? self.respond(ResourceResponse(status: 400, type: "application/json",
                                data: (try? JSONEncoder().encode(["error": error.localizedDescription])) ?? Data()), request: request)
                        }
                    }
                } else if done || error != nil { self.close() }
                else { self.receive() }
            }
        }
    }
    func parse() -> ResourceRequest? {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let text = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { close(); return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let size = Int(headers["content-length"] ?? "0"), size >= 0, size <= 32 * 1024 * 1024 else { close(); return nil }
        guard buffer.count - split.upperBound >= size else { return nil }
        return ResourceRequest(method: String(first[0]), path: String(first[1]), headers: headers,
                               body: buffer.subdata(in: split.upperBound..<(split.upperBound + size)))
    }
    func respond(_ response: ResourceResponse, request: ResourceRequest) throws {
        guard !closed else { return }
        var response = response
        let size: Int
        if let url = response.file {
            file = try FileHandle(forReadingFrom: url)
            size = Int(try file!.seekToEnd()); try file!.seek(toOffset: 0)
        } else { size = response.data.count }
        let range: Range<Int>
        do { range = try ResourceServer.byteRange(request.headers["range"], length: size) }
        catch {
            try? file?.close(); file = nil
            response = ResourceResponse(status: 416, headers: ["Content-Range": "bytes */\(size)"])
            return try respond(response, request: ResourceRequest(method: "HEAD", path: request.path, headers: [:], body: Data()))
        }
        if request.headers["range"] != nil {
            response.status = 206; response.headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)"
        }
        response.headers.merge(["Content-Type": response.type, "Content-Length": "\(range.count)", "Accept-Ranges":"bytes",
                                "Connection":"close", "Cache-Control":"no-store", "X-Content-Type-Options":"nosniff"]) { a, _ in a }
        var head = "HTTP/1.1 \(response.status) Response\r\n"
        for (key, value) in response.headers { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        var first = Data(head.utf8)
        if request.method == "HEAD" { remaining = 0 }
        else if let file { try file.seek(toOffset: UInt64(range.lowerBound)); remaining = range.count }
        else { first.append(response.data.subdata(in: range)); remaining = 0 }
        send(first)
    }
    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                guard error == nil, self.remaining > 0, let file = self.file else { self.close(); return }
                do {
                    let chunk = try file.read(upToCount: min(self.remaining, 256 * 1024)) ?? Data()
                    guard !chunk.isEmpty else { self.close(); return }
                    self.remaining -= chunk.count; self.send(chunk)
                } catch { self.close() }
            }
        })
    }
}
