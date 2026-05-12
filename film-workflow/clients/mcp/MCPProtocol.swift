import Foundation

/// Minimal JSON-RPC 2.0 + MCP envelope types. We accept a permissive request shape
/// (id can be string, number, or null) and re-emit ids as JSON values rather than
/// parsing them strictly, so we don't need a custom AnyCodable.
enum MCPProtocol {
    static let mcpProtocolVersion = "2025-03-26"
    static let serverName = "film-workflow"
    static let serverVersion = "0.1.0"
}

/// JSON-RPC error codes.
enum MCPRPCError: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

/// Loose representation of an incoming JSON-RPC request. We keep `id` as raw JSON
/// data so we can echo it back unchanged (per spec).
struct MCPRequest {
    let method: String
    let params: Any?
    /// Raw id JSON ("null", "1", "\"abc\"") — pass through unchanged in responses.
    let idLiteral: String
    /// True when `id` is missing or null, i.e. a notification.
    let isNotification: Bool
}

enum MCPRequestParseError: Error {
    case notJSON
    case wrongShape
}

extension MCPRequest {
    static func parse(jsonData: Data) throws -> MCPRequest {
        guard let obj = try JSONSerialization.jsonObject(
            with: jsonData,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw MCPRequestParseError.notJSON
        }
        guard let method = obj["method"] as? String else {
            throw MCPRequestParseError.wrongShape
        }
        let params = obj["params"]
        let idLiteral: String
        let isNotification: Bool
        if let id = obj["id"] {
            isNotification = id is NSNull
            if let n = id as? NSNumber {
                idLiteral = n.stringValue
            } else if let s = id as? String {
                idLiteral = encodeJSONString(s)
            } else {
                idLiteral = "null"
            }
        } else {
            idLiteral = "null"
            isNotification = true
        }
        return MCPRequest(method: method, params: params, idLiteral: idLiteral, isNotification: isNotification)
    }
}

/// Build a JSON-RPC 2.0 success response payload as raw JSON bytes.
func mcpSuccessJSON(idLiteral: String, result: Any) -> Data {
    let resultJSON = (try? JSONSerialization.data(withJSONObject: result, options: []))
        ?? Data("null".utf8)
    let prefix = "{\"jsonrpc\":\"2.0\",\"id\":\(idLiteral),\"result\":"
    let suffix = "}"
    var out = Data(prefix.utf8)
    out.append(resultJSON)
    out.append(Data(suffix.utf8))
    return out
}

/// Build a JSON-RPC 2.0 error response payload as raw JSON bytes.
func mcpErrorJSON(idLiteral: String, code: MCPRPCError, message: String, data: Any? = nil) -> Data {
    var error: [String: Any] = ["code": code.rawValue, "message": message]
    if let data { error["data"] = data }
    let payload: [String: Any] = [
        "jsonrpc": "2.0",
        "id": NSNull(),
        "error": error
    ]
    // Replace id placeholder with raw literal (NSNull serialization → null)
    var data = (try? JSONSerialization.data(withJSONObject: payload, options: []))
        ?? Data("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32603,\"message\":\"internal\"}}".utf8)
    if idLiteral != "null" {
        // Rewrite "id":null → "id":<literal>. Safe because we serialized payload above.
        if let nullRange = String(data: data, encoding: .utf8)?.range(of: "\"id\":null") {
            let s = String(data: data, encoding: .utf8) ?? ""
            let rewritten = s.replacingOccurrences(of: "\"id\":null", with: "\"id\":\(idLiteral)", range: nullRange)
            data = Data(rewritten.utf8)
        }
    }
    return data
}

private func encodeJSONString(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data("[]".utf8)
    var encoded = String(data: data, encoding: .utf8) ?? "[\"\"]"
    if encoded.hasPrefix("[") { encoded.removeFirst() }
    if encoded.hasSuffix("]") { encoded.removeLast() }
    return encoded
}

/// MCP `tools/list` entry. Accepts the JSON-Schema for `inputSchema` as an `[String: Any]`.
struct MCPToolDescriptor {
    let name: String
    let description: String
    let inputSchema: [String: Any]

    var dictionary: [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": inputSchema
        ]
    }
}
