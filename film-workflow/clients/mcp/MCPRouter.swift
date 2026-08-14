import Foundation
import SwiftData

/// HTTP-level routing + auth + JSON-RPC dispatch.
@MainActor
enum MCPRouter {
    static func handle(
        request: MCPHTTP.Request,
        container: ModelContainer,
        settings: MCPSettings
    ) async -> Data {
        // Health/info GETs are always public.
        if request.method == "GET" && (request.path == "/" || request.path == "/health") {
            let body = #"{"name":"\#(MCPProtocol.serverName)","version":"\#(MCPProtocol.serverVersion)","mcp":"\#(MCPProtocol.mcpProtocolVersion)"}"#
            return MCPHTTP.makeResponse(status: 200, contentType: "application/json", body: Data(body.utf8))
        }

        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" else {
            return MCPHTTP.makeResponse(status: 404, contentType: "text/plain", body: Data("not found".utf8))
        }

        if request.method == "GET" {
            // SSE not supported in v1; signal that.
            return MCPHTTP.makeResponse(status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8))
        }
        guard request.method == "POST" else {
            return MCPHTTP.makeResponse(status: 405, contentType: "text/plain", body: Data("Method Not Allowed".utf8))
        }

        // Account-backed tools can spend prepaid credits, so even localhost
        // requires the local MCP token while subscription mode is selected.
        let usesSubscription = (try? AppConfig.loadFromKeychain())?.usesSubscription == true
        if settings.bindAll || usesSubscription {
            let header = request.headers["authorization"] ?? ""
            let provided = header.lowercased().hasPrefix("bearer ")
                ? String(header.dropFirst("bearer ".count)).trimmingCharacters(in: .whitespaces)
                : ""
            let expected = settings.token ?? ""
            if expected.isEmpty || provided != expected {
                return MCPHTTP.makeResponse(
                    status: 401,
                    contentType: "application/json",
                    body: Data(#"{"error":"unauthorized"}"#.utf8),
                    extraHeaders: [("WWW-Authenticate", "Bearer")]
                )
            }
        }

        let body = request.body
        let parsed: MCPRequest
        do {
            parsed = try MCPRequest.parse(jsonData: body)
        } catch {
            let err = mcpErrorJSON(idLiteral: "null", code: .parseError, message: "JSON parse error")
            return MCPHTTP.makeResponse(status: 200, contentType: "application/json", body: err)
        }

        if parsed.isNotification {
            // No response for notifications.
            return MCPHTTP.makeResponse(status: 204)
        }

        let payload = await dispatch(method: parsed.method, idLiteral: parsed.idLiteral, params: parsed.params, container: container)
        return MCPHTTP.makeResponse(status: 200, contentType: "application/json", body: payload)
    }

    // MARK: - JSON-RPC dispatch

    static func dispatch(
        method: String,
        idLiteral: String,
        params: Any?,
        container: ModelContainer
    ) async -> Data {
        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": MCPProtocol.mcpProtocolVersion,
                "capabilities": [
                    "tools": ["listChanged": false] as [String: Any]
                ],
                "serverInfo": [
                    "name": MCPProtocol.serverName,
                    "version": MCPProtocol.serverVersion
                ]
            ]
            return mcpSuccessJSON(idLiteral: idLiteral, result: result)

        case "tools/list":
            let tools = MCPToolRegistry.allDescriptors()
            let result: [String: Any] = [
                "tools": tools.map(\.dictionary)
            ]
            return mcpSuccessJSON(idLiteral: idLiteral, result: result)

        case "tools/call":
            guard let p = params as? [String: Any],
                  let name = p["name"] as? String else {
                return mcpErrorJSON(idLiteral: idLiteral, code: .invalidParams, message: "missing tool name")
            }
            let args = (p["arguments"] as? [String: Any]) ?? [:]
            do {
                let toolResult = try await MCPToolRegistry.invoke(
                    name: name, arguments: args, container: container
                )
                return mcpSuccessJSON(idLiteral: idLiteral, result: toolResult)
            } catch let e as MCPToolError {
                let payload: [String: Any] = [
                    "content": [["type": "text", "text": e.localizedDescription]],
                    "isError": true
                ]
                return mcpSuccessJSON(idLiteral: idLiteral, result: payload)
            } catch {
                let payload: [String: Any] = [
                    "content": [["type": "text", "text": error.localizedDescription]],
                    "isError": true
                ]
                return mcpSuccessJSON(idLiteral: idLiteral, result: payload)
            }

        case "ping":
            return mcpSuccessJSON(idLiteral: idLiteral, result: [String: Any]())

        default:
            return mcpErrorJSON(idLiteral: idLiteral, code: .methodNotFound, message: "Method not found: \(method)")
        }
    }
}

enum MCPToolError: LocalizedError {
    case invalidArguments(String)
    case unknownProjectType(String)
    case projectNotFound(String)
    case macOSOnly
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let m): return "invalid arguments: \(m)"
        case .unknownProjectType(let t): return "unknown project type: \(t) (must be one of: narrative, music, image, remotion, caption)"
        case .projectNotFound(let id): return "project not found: \(id)"
        case .macOSOnly: return "this tool is only available on macOS"
        case .underlying(let e): return e.localizedDescription
        }
    }
}
