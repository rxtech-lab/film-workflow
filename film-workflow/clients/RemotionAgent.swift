#if os(macOS)
import Foundation

enum RemotionAgentError: LocalizedError {
    case missingLLMConfig
    case maxIterationsExceeded
    case invalidToolArguments(name: String, raw: String)
    case pathOutsideProject(String)
    case fileNotFound(String)
    case oldStringNotFound(path: String)
    case oldStringNotUnique(path: String, count: Int)

    var errorDescription: String? {
        switch self {
        case .missingLLMConfig:
            return "OpenAI endpoint, key, or model is not configured. Set it in Settings before chatting."
        case .maxIterationsExceeded:
            return "The agent did not finalize within the iteration limit."
        case .invalidToolArguments(let name, let raw):
            return "Tool \(name) was called with invalid arguments: \(raw)"
        case .pathOutsideProject(let p):
            return "Path is outside the project directory: \(p)"
        case .fileNotFound(let p):
            return "File not found: \(p)"
        case .oldStringNotFound(let p):
            return "edit_file: old_string was not found in \(p)"
        case .oldStringNotUnique(let p, let count):
            return "edit_file: old_string matches \(count) places in \(p) — make it unique"
        }
    }
}

enum RemotionAgentEvent {
    case status(String)
    case toolCall(id: String, name: String, args: String)
    case toolResult(id: String, name: String, summary: String, ok: Bool)
    case assistantText(String)
    /// Emitted whenever a file is written or edited. `content` is the full new content of the file.
    case fileWritten(path: String, content: String)
    /// Emitted once when the loop exits cleanly (model returned no further tool calls).
    case completed
}

enum RemotionAgent {

    private static let maxIterations = 20
    /// Cap a single read_file response to avoid blowing the context window.
    private static let maxReadBytes = 200_000

    static func runEdit(
        project: RemotionProject,
        userInstruction: String,
        history: [RemotionMessage],
        config: AppConfig
    ) -> AsyncThrowingStream<RemotionAgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runLoop(
                        project: project,
                        userInstruction: userInstruction,
                        history: history,
                        config: config,
                        emit: { continuation.yield($0) }
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loop

    private static func runLoop(
        project: RemotionProject,
        userInstruction: String,
        history: [RemotionMessage],
        config: AppConfig,
        emit: @escaping (RemotionAgentEvent) -> Void
    ) async throws {
        guard !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty,
              !config.openAIModel.isEmpty else {
            throw RemotionAgentError.missingLLMConfig
        }

        let projectId = project.id
        let projectDir = await MainActor.run {
            try? RemotionRuntime.shared.prepareProjectDirectory(id: projectId)
        } ?? FileStorage.remotionProjectDir(id: projectId)
        // Stage any assets the user has added to the project (images, reference, music) into
        // public/ so staticFile() resolves and the asset list below reflects current state.
        _ = try? RemotionCodeBuilder.prepareAssets(project: project)
        let runId = UUID().uuidString.prefix(8).lowercased()
        let fps = max(1, project.compositionFps)
        let durationFrames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))

        // Cache the static prefix (system prompt + frozen project state) so Vercel AI
        // Gateway pins prompt-cache breakpoints there. Each loop iteration re-uses these
        // tokens; only newly appended tool results vary.
        var messages: [OpenAIRichMessage] = []
        messages.append(OpenAIRichMessage(
            role: "system",
            content: systemPrompt(project: project),
            cacheControl: true
        ))

        let priorTurns = history.suffix(20)
        for msg in priorTurns where msg.role != RemotionMessageRole.system.rawValue {
            messages.append(OpenAIRichMessage(role: msg.role, content: msg.content))
        }

        let publicAssets = listPublicAssets(projectDir: projectDir)
        let assetsBlock: String
        if publicAssets.isEmpty {
            assetsBlock = "Available static assets in public/: (none)"
        } else {
            assetsBlock = "Available static assets in public/ — reference ONLY these basenames via staticFile(\"…\"):\n" +
                publicAssets.map { "- \($0)" }.joined(separator: "\n")
        }

        let stateMsg = """
        Current src/Composition.tsx (you can also use list_files / read_file to inspect other files):

        ```tsx
        \(project.compositionSource)
        ```

        \(projectSettingsBlock(project: project, durationFrames: durationFrames, fps: fps))

        \(assetsBlock)

        New instruction: \(userInstruction)

        Inspect the video with the screenshot tools when helpful, then apply your changes with edit_file / write_file. When you're done, simply stop calling tools and reply with a short summary.
        """
        messages.append(OpenAIRichMessage(role: "user", content: stateMsg, cacheControl: true))

        let tools = toolDefinitions(durationSeconds: project.durationSeconds)

        defer {
            RemotionStillCapture.cleanup(projectId: projectId, runId: String(runId))
        }

        for _ in 0..<maxIterations {
            try Task.checkCancellation()

            let response = try await OpenAIClient.chatWithTools(
                messages: messages,
                tools: tools,
                endpoint: config.openAIEndpoint,
                apiKey: config.openAIKey,
                model: config.openAIModel,
                extraBody: ["providerOptions": ["gateway": ["caching": "auto"]]]
            )

            if let text = response.content?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                emit(.assistantText(text))
            }

            if response.toolCalls.isEmpty {
                emit(.completed)
                return
            }

            messages.append(OpenAIRichMessage(
                role: "assistant",
                content: response.content,
                toolCalls: response.toolCalls
            ))

            for call in response.toolCalls {
                try Task.checkCancellation()
                emit(.toolCall(id: call.id, name: call.name, args: call.argumentsJSON))

                do {
                    try await dispatch(
                        call: call,
                        project: project,
                        projectDir: projectDir,
                        durationFrames: durationFrames,
                        fps: fps,
                        runId: String(runId),
                        messages: &messages,
                        emit: emit
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    emit(.toolResult(id: call.id, name: call.name, summary: "failed: \(error.localizedDescription)", ok: false))
                    messages.append(OpenAIRichMessage(
                        role: "tool",
                        content: errorJSON(error.localizedDescription),
                        toolCallId: call.id,
                        name: call.name
                    ))
                }
            }
        }

        throw RemotionAgentError.maxIterationsExceeded
    }

    // MARK: - Tool dispatch

    private static func dispatch(
        call: OpenAIToolCall,
        project: RemotionProject,
        projectDir: URL,
        durationFrames: Int,
        fps: Int,
        runId: String,
        messages: inout [OpenAIRichMessage],
        emit: (RemotionAgentEvent) -> Void
    ) async throws {
        let args = parseArgs(call.argumentsJSON)

        switch call.name {
        case "take_screenshot":
            let timeSeconds = (args["time_seconds"] as? Double)
                ?? (args["time_seconds"] as? Int).map(Double.init)
                ?? 0
            let frame = clamp(Int((timeSeconds * Double(fps)).rounded()), min: 0, max: durationFrames - 1)
            emit(.status(String(format: "Taking screenshot at %.2fs (frame %d)…", timeSeconds, frame)))

            let url = try await RemotionStillCapture.still(
                projectId: project.id,
                frame: frame,
                runId: runId
            )
            let dataURL = try makeImageDataURL(url: url)
            let summary = "frame \(frame) (\(String(format: "%.2f", timeSeconds))s)"
            emit(.toolResult(id: call.id, name: call.name, summary: summary, ok: true))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: "{\"ok\":true,\"frame\":\(frame)}",
                toolCallId: call.id,
                name: call.name
            ))
            messages.append(OpenAIRichMessage(
                role: "user",
                parts: [.text("Screenshot at \(summary):"), .imageURL(dataURL)]
            ))

        case "take_screenshots":
            let count = clamp(
                (args["count"] as? Int) ?? Int((args["count"] as? Double) ?? 4),
                min: 1, max: 8
            )
            emit(.status("Capturing \(count) frames across the timeline…"))

            let results = try await RemotionStillCapture.stills(
                projectId: project.id,
                count: count,
                durationFrames: durationFrames,
                runId: runId
            )
            let frameList = results.map { String($0.frame) }.joined(separator: ", ")
            let summary = "\(results.count) frames at \(frameList)"
            emit(.toolResult(id: call.id, name: call.name, summary: summary, ok: true))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: "{\"ok\":true,\"frames\":[\(results.map { String($0.frame) }.joined(separator: ","))]}",
                toolCallId: call.id,
                name: call.name
            ))
            var parts: [OpenAIContentPart] = [
                .text("\(results.count) evenly-spaced screenshots (frames in order: \(frameList)):")
            ]
            for r in results {
                let dataURL = try makeImageDataURL(url: r.url)
                parts.append(.text("Frame \(r.frame) (\(String(format: "%.2f", Double(r.frame) / Double(fps)))s):"))
                parts.append(.imageURL(dataURL))
            }
            messages.append(OpenAIRichMessage(role: "user", parts: parts))

        case "list_files":
            let entries = RemotionProjectFiles.list(projectDir: projectDir)
            emit(.toolResult(id: call.id, name: call.name, summary: "\(entries.count) files", ok: true))
            let body = entries.joined(separator: "\n")
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: body.isEmpty ? "(no files)" : body,
                toolCallId: call.id,
                name: call.name
            ))

        case "read_file":
            guard let pathArg = args["path"] as? String, !pathArg.isEmpty else {
                throw RemotionAgentError.invalidToolArguments(name: call.name, raw: call.argumentsJSON)
            }
            let url = try resolveProjectPath(pathArg, projectDir: projectDir)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw RemotionAgentError.fileNotFound(pathArg)
            }
            let data = try Data(contentsOf: url)
            let truncated = data.count > maxReadBytes
            let slice = truncated ? data.prefix(maxReadBytes) : data
            let text = String(data: slice, encoding: .utf8)
                ?? "<binary file, \(data.count) bytes>"
            emit(.toolResult(id: call.id, name: call.name, summary: "\(pathArg) (\(data.count) bytes)", ok: true))
            var body = text
            if truncated {
                body += "\n\n[truncated: showing first \(maxReadBytes) of \(data.count) bytes]"
            }
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: body,
                toolCallId: call.id,
                name: call.name
            ))

        case "write_file":
            guard let pathArg = args["path"] as? String, !pathArg.isEmpty,
                  let content = args["content"] as? String else {
                throw RemotionAgentError.invalidToolArguments(name: call.name, raw: call.argumentsJSON)
            }
            let url = try resolveProjectPath(pathArg, projectDir: projectDir)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            emit(.toolResult(id: call.id, name: call.name, summary: "wrote \(pathArg) (\(content.count) chars)", ok: true))
            emit(.fileWritten(path: pathArg, content: content))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: "{\"ok\":true,\"path\":\(jsonString(pathArg)),\"bytes\":\(content.utf8.count)}",
                toolCallId: call.id,
                name: call.name
            ))

        case "edit_file":
            guard let pathArg = args["path"] as? String, !pathArg.isEmpty else {
                throw RemotionAgentError.invalidToolArguments(name: call.name, raw: call.argumentsJSON)
            }
            let oldString = (args["old_string"] as? String) ?? ""
            let newString = (args["new_string"] as? String) ?? ""
            let url = try resolveProjectPath(pathArg, projectDir: projectDir)

            let exists = FileManager.default.fileExists(atPath: url.path)
            let resultContent: String
            let summary: String
            if !exists {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try newString.write(to: url, atomically: true, encoding: .utf8)
                resultContent = newString
                summary = "created \(pathArg) (\(newString.count) chars)"
            } else {
                let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                let occurrences = current.components(separatedBy: oldString).count - 1
                if oldString.isEmpty {
                    // Treat empty old_string + existing file as "overwrite".
                    try newString.write(to: url, atomically: true, encoding: .utf8)
                    resultContent = newString
                    summary = "overwrote \(pathArg) (\(newString.count) chars)"
                } else if occurrences == 0 {
                    throw RemotionAgentError.oldStringNotFound(path: pathArg)
                } else if occurrences > 1 {
                    throw RemotionAgentError.oldStringNotUnique(path: pathArg, count: occurrences)
                } else {
                    let updated = current.replacingOccurrences(of: oldString, with: newString)
                    try updated.write(to: url, atomically: true, encoding: .utf8)
                    resultContent = updated
                    summary = "edited \(pathArg) (\(updated.count) chars)"
                }
            }

            emit(.toolResult(id: call.id, name: call.name, summary: summary, ok: true))
            emit(.fileWritten(path: pathArg, content: resultContent))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: "{\"ok\":true,\"path\":\(jsonString(pathArg)),\"bytes\":\(resultContent.utf8.count)}",
                toolCallId: call.id,
                name: call.name
            ))

        default:
            emit(.toolResult(id: call.id, name: call.name, summary: "unknown tool", ok: true))
            messages.append(OpenAIRichMessage(
                role: "tool",
                content: "{\"ok\":false,\"error\":\"unknown tool\"}",
                toolCallId: call.id,
                name: call.name
            ))
        }
    }

    // MARK: - Tool definitions

    private static func toolDefinitions(durationSeconds: Double) -> [OpenAIToolDefinition] {
        [
            OpenAIToolDefinition(
                name: "take_screenshot",
                description: "Render a single PNG of the current composition at the given timestamp so you can SEE what's currently on screen. Cheap.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "time_seconds": [
                            "type": "number",
                            "minimum": 0,
                            "maximum": durationSeconds,
                            "description": "Timestamp in seconds (0 to \(durationSeconds))."
                        ]
                    ],
                    "required": ["time_seconds"]
                ]
            ),
            OpenAIToolDefinition(
                name: "take_screenshots",
                description: "Render N evenly-spaced PNGs covering the whole timeline so you can preview pacing/animation.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "count": [
                            "type": "integer",
                            "minimum": 2,
                            "maximum": 8,
                            "description": "Number of evenly-spaced frames. 3–6 is usually enough."
                        ]
                    ],
                    "required": ["count"]
                ]
            ),
            OpenAIToolDefinition(
                name: "list_files",
                description: "List all source files in the project (relative paths). Excludes node_modules, build artifacts, and screenshot scratch dirs. Use this to discover the project layout before reading or editing.",
                parametersSchema: [
                    "type": "object",
                    "properties": [:] as [String: Any],
                    "required": [] as [Any]
                ]
            ),
            OpenAIToolDefinition(
                name: "read_file",
                description: "Read the full text contents of a file in the project. Path is relative to the project root (e.g. \"src/Composition.tsx\").",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path inside the project, e.g. \"src/Composition.tsx\" or \"src/components/Title.tsx\"."
                        ]
                    ],
                    "required": ["path"]
                ]
            ),
            OpenAIToolDefinition(
                name: "write_file",
                description: "Write (create or overwrite) the full contents of a file. Use this for new files or full rewrites. Prefer edit_file for targeted partial changes.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path inside the project. Parent directories are created as needed."
                        ],
                        "content": [
                            "type": "string",
                            "description": "Full file contents."
                        ]
                    ],
                    "required": ["path", "content"]
                ]
            ),
            OpenAIToolDefinition(
                name: "edit_file",
                description: "Apply a targeted edit to a file. If the file doesn't exist, it's created with new_string as the content (old_string ignored). If it exists, replaces a single exact occurrence of old_string with new_string — old_string MUST appear exactly once.",
                parametersSchema: [
                    "type": "object",
                    "properties": [
                        "path": [
                            "type": "string",
                            "description": "Relative path inside the project."
                        ],
                        "old_string": [
                            "type": "string",
                            "description": "Exact text to replace. Must occur exactly once in the existing file. Pass empty string when creating a new file or overwriting wholesale."
                        ],
                        "new_string": [
                            "type": "string",
                            "description": "Replacement text. When the file doesn't exist, this becomes the full new content."
                        ]
                    ],
                    "required": ["path", "old_string", "new_string"]
                ]
            )
        ]
    }

    // MARK: - File helpers

    private static func resolveProjectPath(_ relative: String, projectDir: URL) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.contains("..") {
            throw RemotionAgentError.pathOutsideProject(relative)
        }
        let candidate = projectDir.appendingPathComponent(trimmed).standardizedFileURL
        let projectStd = projectDir.standardizedFileURL.path
        let candidatePath = candidate.path
        if !(candidatePath == projectStd || candidatePath.hasPrefix(projectStd + "/")) {
            throw RemotionAgentError.pathOutsideProject(relative)
        }
        return candidate
    }

    // MARK: - Prompt

    private static func projectSettingsBlock(
        project: RemotionProject,
        durationFrames: Int,
        fps: Int
    ) -> String {
        var lines: [String] = ["Project settings:"]
        lines.append("- Name: \(project.name)")
        lines.append("- Resolution: \(project.compositionWidth)×\(project.compositionHeight)")
        lines.append("- Duration: \(project.durationSeconds)s (\(durationFrames) frames at \(fps) fps)")
        lines.append("- Theme color: \(project.themeColorHex)")
        let text = project.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            lines.append("- Script / text:\n\(text)")
        }
        let standingPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standingPrompt.isEmpty {
            lines.append("- Project brief (keep edits consistent with this):\n\(standingPrompt)")
        }
        return lines.joined(separator: "\n")
    }

    private static func systemPrompt(project: RemotionProject) -> String {
        _ = project
        let prompt = """
        You are an expert Remotion (React) developer working in a sandboxed project directory. You have file-system tools (list_files, read_file, write_file, edit_file) and visual tools (take_screenshot, take_screenshots) for reviewing the current video.

        How to work:
        - Before non-trivial visual changes, call take_screenshot for one moment, or take_screenshots for an evenly-spaced sweep.
        - Use list_files when unsure of the layout. Use read_file to inspect a file before editing.
        - Use edit_file for targeted partial changes — specify a unique old_string and the new_string. If the file doesn't exist yet, edit_file creates it with new_string as the content.
        - Use write_file when creating a new file or replacing a whole file.
        - When you're done, simply STOP calling tools and reply with a short natural-language summary of what you changed. The loop ends as soon as you stop calling tools.

        File layout — STRICTLY one component per file:
        - src/Composition.tsx is the orchestration entry point ONLY: it composes the timeline (Sequence layout, top-level AbsoluteFill, COMPOSITION_* exports, MyComposition) and imports sub-components from src/components/. It must NOT define non-trivial inline components, logos, scenes, or visual primitives.
        - Every reusable visual element, scene, logo, title card, transition, animation, etc. lives in its own file under src/components/<PascalCaseName>.tsx with a single default-exported component per file.
        - When adding a new visual element: CREATE a new src/components/<Name>.tsx via write_file and import it into Composition.tsx.
        - When editing an existing element: edit ITS file directly, not Composition.tsx.
        - If you find Composition.tsx contains inline components (legacy code), extract them into their own files in src/components/ as you make changes — leave the codebase a little tidier each turn.
        - Before creating a new file, check src/components/ via list_files to avoid duplicating existing components.

        Hard requirements:
        - src/Composition.tsx must export: COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT, and MyComposition. Root.tsx imports these by name.
        - Reference local assets via staticFile("filename.ext"). Files placed under public/ are exposed by their basename only.
        - NEVER invent asset filenames. Only call staticFile() with a basename listed in the per-turn "Available static assets in public/" block, or one you confirmed via list_files. If you need an image that isn't there, say so in your reply instead of guessing a name.
        - Use Remotion primitives: AbsoluteFill, Sequence, Img, Audio, Video, useCurrentFrame, useVideoConfig, interpolate, spring.
        - Do not add new packages — only react, react-dom, and remotion are available.
        - Valid TypeScript JSX only, no markdown fences inside files.
        """
        return prompt
    }

    // MARK: - Helpers

    private static func listPublicAssets(projectDir: URL) -> [String] {
        let publicDir = projectDir.appendingPathComponent("public", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: publicDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    private static func parseArgs(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return dict
    }

    private static func makeImageDataURL(url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let base64 = data.base64EncodedString()
        let mime = url.pathExtension.lowercased() == "jpg" || url.pathExtension.lowercased() == "jpeg"
            ? "image/jpeg" : "image/png"
        return "data:\(mime);base64,\(base64)"
    }

    private static func errorJSON(_ message: String) -> String {
        "{\"ok\":false,\"error\":\(jsonString(message))}"
    }

    private static func jsonString(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s], options: [.fragmentsAllowed])) ?? Data()
        guard var encoded = String(data: data, encoding: .utf8) else { return "\"\"" }
        if encoded.hasPrefix("["), encoded.hasSuffix("]") {
            encoded.removeFirst()
            encoded.removeLast()
        }
        return encoded
    }

    private static func clamp(_ x: Int, min lo: Int, max hi: Int) -> Int {
        Swift.max(lo, Swift.min(hi, x))
    }
}
#endif
