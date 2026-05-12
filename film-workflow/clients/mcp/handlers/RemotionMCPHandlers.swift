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
            description: "Write (create or overwrite) a file in a remotion project. Parent directories are created. NOTE: package.json, package-lock.json, bun.lockb, tsconfig.json, remotion.config.ts and anything under node_modules/ are protected and will be rejected — do not attempt to add npm packages.",
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
            description: "Targeted edit. If file exists: replace a single exact occurrence of old_string with new_string (must occur exactly once; pass empty old_string to overwrite). If file doesn't exist: create it with new_string. Same protected-paths list as remotion_write_file applies.",
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
        ),
        MCPToolDescriptor(
            name: "remotion_add_image",
            description: "Attach an image asset to a remotion project (max 10) by copying a file from disk. Format-agnostic — PNG / JPEG / WebP / GIF / SVG / AVIF / BMP — the file's extension is preserved; never re-encode the bytes elsewhere before calling this tool. Reads `source_path` (absolute or file:// URL on the local filesystem), copies it into the app's image library, appends the relative path to the project's imagePaths, and stages it into public/upload/ so `staticFile(\"upload/<filename>\")` resolves. Returns `path` (project-relative) and `static_path` (the staticFile arg).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "source_path": ["type": "string", "description": "Absolute filesystem path or file:// URL of the image on the local machine. The file is copied (not moved); the source is left untouched."] as [String: Any]
                ],
                "required": ["project_id", "source_path"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_remove_image",
            description: "Detach a user-uploaded image from a remotion project. Identify it by zero-based `index` in imagePaths or by `path` (the relative path stored in imagePaths). Deletes the underlying file and the corresponding public/upload/ copy.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "index": ["type": "integer", "minimum": 0, "description": "Zero-based index in imagePaths. One of `index` or `path` is required."] as [String: Any],
                    "path": ["type": "string", "description": "Relative path stored in imagePaths (e.g. \"images/<uuid>.png\"). One of `index` or `path` is required."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_add_audio",
            description: "Attach any audio file to a remotion project by copying it from disk. Covers ALL audio kinds — background music, sound effects, foley, voiceover / narration, ambience, dialogue stems, jingles, etc. Format-agnostic: mp3, wav, m4a, aac, ogg, flac, etc.; the file's extension is preserved, never re-encode. Reads `source_path` (absolute or file:// URL on the local filesystem), copies into the app's library, appends the relative path to the project's audioFilePaths, and stages into public/audio/ so `staticFile(\"audio/<filename>\")` resolves from <Audio src={…} />. Returns `path` (project-relative) and `static_path` (the staticFile arg). Multiple tracks are supported — call this tool once per file.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "source_path": ["type": "string", "description": "Absolute filesystem path or file:// URL of the audio file on the local machine. The file is copied (not moved); the source is left untouched."] as [String: Any]
                ],
                "required": ["project_id", "source_path"]
            ]
        ),
        MCPToolDescriptor(
            name: "remotion_remove_audio",
            description: "Detach an audio file (music, SFX, narration, etc.) from a remotion project. Identify it by zero-based `index` in audioFilePaths or by `path` (the relative path stored in audioFilePaths). Deletes the underlying file and the corresponding public/audio/ copy.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "project_id": ["type": "string"] as [String: Any],
                    "index": ["type": "integer", "minimum": 0, "description": "Zero-based index in audioFilePaths. One of `index` or `path` is required."] as [String: Any],
                    "path": ["type": "string", "description": "Relative path stored in audioFilePaths (e.g. \"images/<uuid>.mp3\"). One of `index` or `path` is required."] as [String: Any]
                ],
                "required": ["project_id"]
            ]
        )
    ]

    private static let maxUploadedImages = 10

    /// Resolves the `source_path` argument (absolute filesystem path or `file://` URL)
    /// into a URL pointing at an existing regular file on disk. The user/agent is
    /// expected to hand us a real local path; we don't fetch over the network.
    private static func resolveLocalSourcePath(_ arguments: [String: Any]) throws -> URL {
        guard let raw = (arguments["source_path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            throw MCPToolError.invalidArguments("missing source_path")
        }
        let url: URL
        if raw.hasPrefix("file://"), let parsed = URL(string: raw) {
            url = parsed
        } else if raw.hasPrefix("/") {
            url = URL(fileURLWithPath: raw)
        } else {
            throw MCPToolError.invalidArguments("source_path must be an absolute path or file:// URL")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else {
            throw MCPToolError.invalidArguments("source_path does not point to a readable file: \(url.path)")
        }
        return url
    }

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

        case "remotion_add_image":
            if project.imagePaths.count >= maxUploadedImages {
                throw MCPToolError.invalidArguments("project already has the maximum of \(maxUploadedImages) uploaded images")
            }
            let sourceURL = try resolveLocalSourcePath(arguments)
            let imageData = try Data(contentsOf: sourceURL)
            let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension.lowercased()
            let stored = try FileStorage.saveImage(imageData, fileExtension: ext)
            project.imagePaths.append(stored)
            project.updatedAt = Date()
            try context.save()
            _ = try? RemotionCodeBuilder.prepareAssets(project: project)
            let publicName = (stored as NSString).lastPathComponent
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "path": stored,
                "static_path": "upload/\(publicName)",
                "index": project.imagePaths.count - 1,
                "bytes": imageData.count
            ] as [String: Any])

        case "remotion_remove_image":
            var resolvedIndex: Int?
            if let n = arguments["index"] as? Int { resolvedIndex = n }
            else if let n = arguments["index"] as? Double { resolvedIndex = Int(n) }
            if resolvedIndex == nil, let p = arguments["path"] as? String {
                resolvedIndex = project.imagePaths.firstIndex(of: p)
            }
            guard let idx = resolvedIndex, project.imagePaths.indices.contains(idx) else {
                throw MCPToolError.invalidArguments("provide a valid `index` or `path` matching an entry in imagePaths")
            }
            let removedPath = project.imagePaths.remove(at: idx)
            FileStorage.deleteFile(at: removedPath)
            let uploadCopy = projectDir
                .appendingPathComponent("public", isDirectory: true)
                .appendingPathComponent("upload", isDirectory: true)
                .appendingPathComponent((removedPath as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: uploadCopy)
            project.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "removed_path": removedPath,
                "remaining": project.imagePaths.count
            ] as [String: Any])

        case "remotion_add_audio":
            let sourceURL = try resolveLocalSourcePath(arguments)
            let audioData = try Data(contentsOf: sourceURL)
            let ext = sourceURL.pathExtension.isEmpty ? "mp3" : sourceURL.pathExtension.lowercased()
            let filename = UUID().uuidString + "." + ext
            let dest = FileStorage.imagesDir.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at: FileStorage.imagesDir, withIntermediateDirectories: true)
            try audioData.write(to: dest)
            let stored = "images/" + filename
            project.audioFilePaths.append(stored)
            project.updatedAt = Date()
            try context.save()
            _ = try? RemotionCodeBuilder.prepareAssets(project: project)
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "path": stored,
                "static_path": "audio/\(filename)",
                "index": project.audioFilePaths.count - 1,
                "bytes": audioData.count
            ] as [String: Any])

        case "remotion_remove_audio":
            var resolvedIndex: Int?
            if let n = arguments["index"] as? Int { resolvedIndex = n }
            else if let n = arguments["index"] as? Double { resolvedIndex = Int(n) }
            if resolvedIndex == nil, let p = arguments["path"] as? String {
                resolvedIndex = project.audioFilePaths.firstIndex(of: p)
            }
            guard let idx = resolvedIndex, project.audioFilePaths.indices.contains(idx) else {
                throw MCPToolError.invalidArguments("provide a valid `index` or `path` matching an entry in audioFilePaths")
            }
            let removedPath = project.audioFilePaths.remove(at: idx)
            FileStorage.deleteFile(at: removedPath)
            let publicCopy = projectDir
                .appendingPathComponent("public", isDirectory: true)
                .appendingPathComponent("audio", isDirectory: true)
                .appendingPathComponent((removedPath as NSString).lastPathComponent)
            try? FileManager.default.removeItem(at: publicCopy)
            project.updatedAt = Date()
            try context.save()
            return MCPToolRegistry.jsonResult([
                "ok": true,
                "removed_path": removedPath,
                "remaining": project.audioFilePaths.count
            ] as [String: Any])

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
