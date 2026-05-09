#if os(macOS)
import Foundation
import SwiftData

/// Tools that mirror the in-app `RemotionAgent`'s file/screenshot/image-gen toolset.
/// Externally-driven agents call these to iterate on a remotion project.
@MainActor
enum RemotionMCPHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "remotion_list_files",
            description: "List source files in a remotion project (relative paths under src/, public/, plus root configs). Excludes node_modules / build output.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_read_file",
            description: "Read a file in a remotion project. Capped at 200KB; the response indicates truncation when applicable.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "path": ["type": "string", "description": "Relative path inside the project, e.g. 'src/Composition.tsx'."] as [String: Any]
                ],
                "required": ["project_id", "path"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_write_file",
            description: "Write (create or overwrite) a file in a remotion project. Parent directories are created.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "path": ["type": "string"] as [String: Any],
                    "content": ["type": "string"] as [String: Any]
                ],
                "required": ["project_id", "path", "content"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_edit_file",
            description: "Targeted edit. If file exists: replace a single exact occurrence of old_string with new_string (must occur exactly once; pass empty old_string to overwrite). If file doesn't exist: create it with new_string.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "path": ["type": "string"] as [String: Any],
                    "old_string": ["type": "string"] as [String: Any],
                    "new_string": ["type": "string"] as [String: Any]
                ],
                "required": ["project_id", "path", "old_string", "new_string"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_take_screenshot",
            description: "Render a single PNG of the composition at the given timestamp and return it as a base64 data URL.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "time_seconds": ["type": "number", "minimum": 0] as [String: Any]
                ],
                "required": ["project_id", "time_seconds"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_take_screenshots",
            description: "Render N evenly-spaced PNG frames covering the timeline (count between 2 and 8).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "count": ["type": "integer", "minimum": 2, "maximum": 8] as [String: Any]
                ],
                "required": ["project_id", "count"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_generate_image",
            description: "Generate an image from a text prompt and save it under public/generated/ in the project. Returns the relative `staticFile()` path.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "prompt": ["type": "string"] as [String: Any],
                    "transparent": ["type": "boolean", "description": "Best-effort transparent background (PNG only)."] as [String: Any],
                    "filename_hint": ["type": "string"] as [String: Any]
                ],
                "required": ["project_id", "prompt"]
            ]
        )
    ]

    static let toolNames: Set<String> = Set(descriptors.map(\.name))

    static func canHandle(_ name: String) -> Bool { toolNames.contains(name) }

    static func handle(
        name: String,
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        guard let projectId = arguments["project_id"] as? String else {
            throw MCPToolError.invalidArguments("missing project_id")
        }
        let project = try MCPProjectHandlers.fetchRemotion(id: projectId, context: context)
        let projectDir = (try? RemotionRuntime.shared.prepareProjectDirectory(id: project.id))
            ?? FileStorage.remotionProjectDir(id: project.id)

        switch name {
        case "remotion_list_files":
            let entries = RemotionProjectFiles.list(projectDir: projectDir)
            return MCPToolRegistry.jsonResult(["files": entries] as [String: Any])

        case "remotion_read_file":
            guard let path = arguments["path"] as? String else {
                throw MCPToolError.invalidArguments("missing path")
            }
            let result = try RemotionTools.readFile(projectDir: projectDir, path: path)
            return MCPToolRegistry.jsonResult([
                "path": path,
                "bytes": result.bytes,
                "truncated": result.truncated,
                "content": result.text
            ] as [String: Any])

        case "remotion_write_file":
            guard let path = arguments["path"] as? String,
                  let content = arguments["content"] as? String else {
                throw MCPToolError.invalidArguments("missing path or content")
            }
            try RemotionTools.writeFile(projectDir: projectDir, path: path, content: content)
            return MCPToolRegistry.jsonResult([
                "ok": true, "path": path, "bytes": content.utf8.count
            ] as [String: Any])

        case "remotion_edit_file":
            guard let path = arguments["path"] as? String else {
                throw MCPToolError.invalidArguments("missing path")
            }
            let oldStr = (arguments["old_string"] as? String) ?? ""
            let newStr = (arguments["new_string"] as? String) ?? ""
            let res = try RemotionTools.editFile(
                projectDir: projectDir, path: path, oldString: oldStr, newString: newStr
            )
            return MCPToolRegistry.jsonResult([
                "ok": true, "path": res.path, "summary": res.summary,
                "bytes": res.content.utf8.count
            ] as [String: Any])

        case "remotion_take_screenshot":
            let t = (arguments["time_seconds"] as? Double)
                ?? (arguments["time_seconds"] as? Int).map(Double.init) ?? 0
            let fps = max(1, project.compositionFps)
            let durationFrames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))
            let frame = max(0, min(Int((t * Double(fps)).rounded()), durationFrames - 1))
            let runId = UUID().uuidString.prefix(8).lowercased()
            defer { RemotionStillCapture.cleanup(projectId: project.id, runId: String(runId)) }
            let url = try await RemotionStillCapture.still(
                projectId: project.id, frame: frame, runId: String(runId)
            )
            let data = try Data(contentsOf: url)
            return [
                "content": [
                    [
                        "type": "image",
                        "data": data.base64EncodedString(),
                        "mimeType": "image/png"
                    ] as [String: Any]
                ],
                "structuredContent": [
                    "frame": frame,
                    "time_seconds": Double(frame) / Double(fps),
                    "bytes": data.count
                ]
            ]

        case "remotion_take_screenshots":
            let count = max(2, min(8,
                (arguments["count"] as? Int)
                    ?? Int((arguments["count"] as? Double) ?? 4)
            ))
            let fps = max(1, project.compositionFps)
            let durationFrames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))
            let runId = UUID().uuidString.prefix(8).lowercased()
            defer { RemotionStillCapture.cleanup(projectId: project.id, runId: String(runId)) }
            let results = try await RemotionStillCapture.stills(
                projectId: project.id, count: count, durationFrames: durationFrames, runId: String(runId)
            )
            var contentParts: [[String: Any]] = []
            var structured: [[String: Any]] = []
            for r in results {
                let data = try Data(contentsOf: r.url)
                contentParts.append([
                    "type": "text",
                    "text": "Frame \(r.frame) (\(String(format: "%.2f", Double(r.frame) / Double(fps)))s):"
                ] as [String: Any])
                contentParts.append([
                    "type": "image",
                    "data": data.base64EncodedString(),
                    "mimeType": "image/png"
                ] as [String: Any])
                structured.append([
                    "frame": r.frame,
                    "time_seconds": Double(r.frame) / Double(fps),
                    "bytes": data.count
                ] as [String: Any])
            }
            return [
                "content": contentParts,
                "structuredContent": ["frames": structured]
            ]

        case "remotion_generate_image":
            guard let prompt = arguments["prompt"] as? String, !prompt.isEmpty else {
                throw MCPToolError.invalidArguments("missing prompt")
            }
            let transparent = (arguments["transparent"] as? Bool) ?? false
            let hint = (arguments["filename_hint"] as? String) ?? ""
            let out = try await RemotionTools.generateImage(
                projectDir: projectDir,
                prompt: prompt,
                transparent: transparent,
                filenameHint: hint
            )
            NotificationCenter.default.post(name: .remotionGeneratedImageWritten, object: project.id)
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "filename": out.staticName,
                "bytes": out.bytes,
                "model": out.model,
                "transparent_applied": out.transparentApplied
            ] as [String: Any])

        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }
}
#endif
