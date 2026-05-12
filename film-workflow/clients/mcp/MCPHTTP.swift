import Foundation

/// Minimal HTTP/1.1 request/response handling — just enough to serve a single MCP
/// endpoint without taking on a server framework. Built on Apple's Network framework
/// already in use by `RemotionRuntime`.
enum MCPHTTP {

    struct Request {
        let method: String
        let path: String
        let headers: [String: String]   // lowercased keys
        let body: Data
    }

    /// Parse a complete HTTP/1.1 request from `buffer`. Returns nil if more bytes are
    /// needed; throws on malformed input. On success, returns the request and the
    /// number of bytes consumed.
    static func parseRequest(buffer: Data) throws -> (Request, Int)? {
        // Find header terminator.
        guard let terminator = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            // Maybe LF-only — be lenient.
            guard let altTerminator = buffer.range(of: Data("\n\n".utf8)) else {
                return nil
            }
            return try parseRequestImpl(buffer: buffer, headerEnd: altTerminator)
        }
        return try parseRequestImpl(buffer: buffer, headerEnd: terminator)
    }

    private static func parseRequestImpl(buffer: Data, headerEnd: Range<Data.Index>) throws -> (Request, Int)? {
        let headerData = buffer.subdata(in: 0..<headerEnd.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError.invalidEncoding
        }
        let lines = headerText.components(separatedBy: CharacterSet.newlines).filter { !$0.isEmpty }
        guard let requestLine = lines.first else {
            throw HTTPParseError.malformedRequestLine
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            throw HTTPParseError.malformedRequestLine
        }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let bodyStart = headerEnd.upperBound
        let contentLength = headers["content-length"].flatMap { Int($0) } ?? 0
        let availableBody = buffer.count - bodyStart
        if availableBody < contentLength {
            return nil  // need more
        }
        let body = contentLength > 0
            ? buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
            : Data()
        let consumed = bodyStart + contentLength
        return (Request(method: method, path: path, headers: headers, body: body), consumed)
    }

    enum HTTPParseError: Error {
        case malformedRequestLine
        case invalidEncoding
    }

    /// Construct an HTTP/1.1 response.
    static func makeResponse(
        status: Int,
        contentType: String? = nil,
        body: Data = Data(),
        extraHeaders: [(String, String)] = []
    ) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reasonPhrase(status))"]
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        lines.append("Content-Length: \(body.count)")
        lines.append("Connection: close")
        lines.append("Cache-Control: no-store")
        for (k, v) in extraHeaders {
            lines.append("\(k): \(v)")
        }
        var head = lines.joined(separator: "\r\n").data(using: .utf8) ?? Data()
        head.append(Data("\r\n\r\n".utf8))
        head.append(body)
        return head
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 408: return "Request Timeout"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }
}
