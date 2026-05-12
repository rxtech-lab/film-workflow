#if os(macOS)
import Foundation

/// Reusable implementations of the file/screenshot/image-gen tools the in-app
/// `RemotionAgent` calls and the MCP server exposes. Behavior mirrors the
/// existing `RemotionAgent.dispatch` cases so both code paths stay aligned.
enum RemotionToolsError: LocalizedError {
    case pathOutsideProject(String)
    case fileNotFound(String)
    case oldStringNotFound(path: String)
    case oldStringNotUnique(path: String, count: Int)
    case imageGenNotConfigured
    case imageGenFailed(message: String, transparentRequested: Bool)
    case protectedPath(String)

    var errorDescription: String? {
        switch self {
        case .pathOutsideProject(let p): return "Path is outside the project directory: \(p)"
        case .fileNotFound(let p): return "File not found: \(p)"
        case .oldStringNotFound(let p): return "edit_file: old_string was not found in \(p)"
        case .oldStringNotUnique(let p, let count): return "edit_file: old_string matches \(count) places in \(p) — make it unique"
        case .imageGenNotConfigured: return "Default image model is not configured. Set Settings → AI Provider → Default image model."
        case .imageGenFailed(let message, let transparent):
            if transparent {
                return "Image generation failed (transparent requested): \(message). Try transparent=false."
            }
            return "Image generation failed: \(message)"
        case .protectedPath(let p):
            return "Path is protected and cannot be modified by tools: \(p). Edit Composition.tsx / src/components instead."
        }
    }
}

enum RemotionTools {
    /// Cap a single read_file response to avoid blowing the context window.
    static let maxReadBytes = 200_000

    /// Files tools must NEVER modify. Bun + Remotion package management is owned
    /// by the runtime; if an LLM rewrites these we end up with broken/inconsistent
    /// projects. Reads are still allowed.
    static let writeProtectedPaths: Set<String> = [
        "package.json",
        "package-lock.json",
        "bun.lockb",
        "tsconfig.json",
        "remotion.config.ts"
    ]

    // MARK: - File ops

    static func resolveProjectPath(_ relative: String, projectDir: URL) throws -> URL {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("/") || trimmed.contains("..") {
            throw RemotionToolsError.pathOutsideProject(relative)
        }
        let candidate = projectDir.appendingPathComponent(trimmed).standardizedFileURL
        let projectStd = projectDir.standardizedFileURL.path
        let candidatePath = candidate.path
        if !(candidatePath == projectStd || candidatePath.hasPrefix(projectStd + "/")) {
            throw RemotionToolsError.pathOutsideProject(relative)
        }
        return candidate
    }

    /// Throws if the relative path targets a runtime-managed file or a path
    /// inside `node_modules/`.
    static func ensureWritable(_ relative: String) throws {
        let trimmed = relative.trimmingCharacters(in: .whitespacesAndNewlines)
        if writeProtectedPaths.contains(trimmed) {
            throw RemotionToolsError.protectedPath(trimmed)
        }
        if trimmed == "node_modules" || trimmed.hasPrefix("node_modules/") {
            throw RemotionToolsError.protectedPath(trimmed)
        }
    }

    struct ReadResult {
        let bytes: Int
        let truncated: Bool
        let text: String
    }

    static func readFile(projectDir: URL, path: String) throws -> ReadResult {
        let url = try resolveProjectPath(path, projectDir: projectDir)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RemotionToolsError.fileNotFound(path)
        }
        let data = try Data(contentsOf: url)
        let truncated = data.count > maxReadBytes
        let slice = truncated ? data.prefix(maxReadBytes) : data
        let text = String(data: slice, encoding: .utf8) ?? "<binary file, \(data.count) bytes>"
        return ReadResult(bytes: data.count, truncated: truncated, text: text)
    }

    static func writeFile(projectDir: URL, path: String, content: String) throws {
        try ensureWritable(path)
        let url = try resolveProjectPath(path, projectDir: projectDir)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    struct EditResult {
        let path: String
        let content: String
        let summary: String
    }

    static func editFile(
        projectDir: URL,
        path: String,
        oldString: String,
        newString: String
    ) throws -> EditResult {
        try ensureWritable(path)
        let url = try resolveProjectPath(path, projectDir: projectDir)
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try newString.write(to: url, atomically: true, encoding: .utf8)
            return EditResult(path: path, content: newString, summary: "created \(path) (\(newString.count) chars)")
        }
        let current = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if oldString.isEmpty {
            try newString.write(to: url, atomically: true, encoding: .utf8)
            return EditResult(path: path, content: newString, summary: "overwrote \(path) (\(newString.count) chars)")
        }
        let occurrences = current.components(separatedBy: oldString).count - 1
        if occurrences == 0 {
            throw RemotionToolsError.oldStringNotFound(path: path)
        }
        if occurrences > 1 {
            throw RemotionToolsError.oldStringNotUnique(path: path, count: occurrences)
        }
        let updated = current.replacingOccurrences(of: oldString, with: newString)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return EditResult(path: path, content: updated, summary: "edited \(path) (\(updated.count) chars)")
    }

    // MARK: - Image generation

    struct GeneratedImageOutput {
        /// e.g. "generated/forest-a1b2c3.png" — relative to public/, suitable for staticFile().
        let staticName: String
        let bytes: Int
        let model: String
        let transparentApplied: Bool
    }

    static func generateImage(
        projectDir: URL,
        prompt: String,
        transparent: Bool,
        filenameHint: String
    ) async throws -> GeneratedImageOutput {
        let imageConfig = (try? AppConfig.loadFromKeychain())
        let model = imageConfig?.defaultImageModel.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let endpoint = imageConfig?.openAIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = imageConfig?.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty, !endpoint.isEmpty, !key.isEmpty else {
            throw RemotionToolsError.imageGenNotConfigured
        }

        let result: ImageGenResult
        do {
            result = try await ImageGenClient.generateImage(
                prompt: prompt,
                model: model,
                endpoint: endpoint,
                apiKey: key,
                format: .png,
                transparent: transparent
            )
        } catch {
            throw RemotionToolsError.imageGenFailed(
                message: error.localizedDescription,
                transparentRequested: transparent
            )
        }

        let generatedDir = projectDir
            .appendingPathComponent("public", isDirectory: true)
            .appendingPathComponent("generated", isDirectory: true)
        try FileManager.default.createDirectory(at: generatedDir, withIntermediateDirectories: true)
        let basename = makeImageBasename(hint: filenameHint, ext: result.fileExtension, in: generatedDir)
        let dest = generatedDir.appendingPathComponent(basename)
        try result.imageData.write(to: dest)

        let transparentApplied = transparent && ImageGenClient.modelLikelySupportsTransparent(model)
        return GeneratedImageOutput(
            staticName: "generated/\(basename)",
            bytes: result.imageData.count,
            model: model,
            transparentApplied: transparentApplied
        )
    }

    static func makeImageBasename(hint: String, ext: String, in publicDir: URL) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let chars = hint.lowercased().map { c -> Character in
            allowed.contains(c) ? c : "-"
        }
        var collapsed = ""
        var lastDash = false
        for c in chars {
            if c == "-" {
                if !lastDash { collapsed.append(c) }
                lastDash = true
            } else {
                collapsed.append(c); lastDash = false
            }
        }
        var base = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if base.isEmpty { base = "image" }
        if base.count > 40 { base = String(base.prefix(40)) }
        let suffix = String(UUID().uuidString.prefix(6).lowercased())
        let safeExt = ext.isEmpty ? "png" : ext
        let candidate = "\(base)-\(suffix).\(safeExt)"
        if FileManager.default.fileExists(atPath: publicDir.appendingPathComponent(candidate).path) {
            return "\(base)-\(UUID().uuidString.lowercased()).\(safeExt)"
        }
        return candidate
    }
}
#endif
