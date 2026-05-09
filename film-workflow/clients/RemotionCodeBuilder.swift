#if os(macOS)
import Foundation

enum RemotionCodeBuilderError: LocalizedError {
    case sourceWriteFailed(String)
    case noResponse
    case missingLLMConfig

    var errorDescription: String? {
        switch self {
        case .sourceWriteFailed(let message):
            return "Failed to write Composition.tsx: \(message)"
        case .noResponse:
            return "The model returned an empty response."
        case .missingLLMConfig:
            return "OpenAI endpoint, key, or model is not configured. Set it in Settings before generating."
        }
    }
}

struct SeededAssets {
    let imageNames: [String]
    let referenceImageName: String?
    let musicName: String?
}

struct RemotionCodeBuilder {

    // MARK: - LLM-driven seed

    /// Copies the project's assets into its public/ dir and returns the asset basenames the LLM can reference.
    static func prepareAssets(project: RemotionProject) throws -> SeededAssets {
        let dir = FileStorage.remotionProjectDir(id: project.id)
        let publicDir = dir.appendingPathComponent("public", isDirectory: true)
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var imageNames: [String] = []
        for relativePath in project.imagePaths {
            if let name = copyAsset(relativePath: relativePath, intoPublic: publicDir) {
                imageNames.append(name)
            }
        }
        var referenceImageName: String?
        if let ref = project.referenceImagePath {
            referenceImageName = copyAsset(relativePath: ref, intoPublic: publicDir)
        }
        var musicName: String?
        if let music = project.musicFilePath {
            musicName = copyAsset(relativePath: music, intoPublic: publicDir)
        }
        return SeededAssets(
            imageNames: imageNames,
            referenceImageName: referenceImageName,
            musicName: musicName
        )
    }

    /// Asks the LLM to write src/Composition.tsx (and optionally extra component files) from scratch
    /// using the form fields and the user prompt. Returns the contents of src/Composition.tsx.
    static func seedWithLLM(project: RemotionProject, config: AppConfig) async throws -> String {
        guard !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty,
              !config.openAIModel.isEmpty else {
            throw RemotionCodeBuilderError.missingLLMConfig
        }

        let assets = try prepareAssets(project: project)

        let userPayload = buildSeedUserPayload(project: project, assets: assets)

        let messages: [OpenAIChatMessage] = [
            OpenAIChatMessage(role: "system", content: seedSystemPrompt),
            OpenAIChatMessage(role: "user", content: userPayload)
        ]

        let raw = try await OpenAIClient.chat(
            messages: messages,
            endpoint: config.openAIEndpoint,
            apiKey: config.openAIKey,
            model: config.openAIModel
        )

        let files = extractFiles(from: raw)
        guard let composition = files.first(where: { $0.path == "src/Composition.tsx" })?.content,
              !composition.isEmpty else {
            throw RemotionCodeBuilderError.noResponse
        }

        let dir = FileStorage.remotionProjectDir(id: project.id)
        for file in files {
            try writeProjectFile(file, in: dir)
        }
        return composition
    }

    private static func writeProjectFile(_ file: SeededFile, in projectDir: URL) throws {
        // Reject path traversal / absolute paths.
        let trimmed = file.path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.contains("..") else { return }
        let target = projectDir.appendingPathComponent(trimmed)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            try file.content.write(to: target, atomically: true, encoding: .utf8)
        } catch {
            throw RemotionCodeBuilderError.sourceWriteFailed(error.localizedDescription)
        }
    }

    static func writeComposition(source: String, to srcDir: URL) throws {
        let path = srcDir.appendingPathComponent("Composition.tsx")
        do {
            try source.write(to: path, atomically: true, encoding: .utf8)
        } catch {
            throw RemotionCodeBuilderError.sourceWriteFailed(error.localizedDescription)
        }
    }

    static func writeComposition(project: RemotionProject, source: String) throws {
        let dir = FileStorage.remotionProjectDir(id: project.id)
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try writeComposition(source: source, to: srcDir)
    }

    /// Rewrites COMPOSITION_WIDTH / COMPOSITION_HEIGHT / COMPOSITION_FPS /
    /// COMPOSITION_DURATION_IN_FRAMES exports inside an existing Composition.tsx so the
    /// project's resolution / fps / duration settings stay authoritative.
    static func patchProjectConstants(in source: String, project: RemotionProject) -> String {
        let fps = max(1, project.compositionFps)
        let frames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))
        var s = source
        s = replaceTopLevelConst(s, name: "COMPOSITION_WIDTH", value: project.compositionWidth)
        s = replaceTopLevelConst(s, name: "COMPOSITION_HEIGHT", value: project.compositionHeight)
        s = replaceTopLevelConst(s, name: "COMPOSITION_FPS", value: fps)
        s = replaceTopLevelConst(s, name: "COMPOSITION_DURATION_IN_FRAMES", value: frames)
        return s
    }

    private static func replaceTopLevelConst(_ source: String, name: String, value: Int) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"export\s+const\s+\#(escaped)\b[^=]*=\s*\d+(?:\.\d+)?"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return source }
        let range = NSRange(source.startIndex..., in: source)
        return re.stringByReplacingMatches(
            in: source,
            range: range,
            withTemplate: "export const \(name) = \(value)"
        )
    }

    // MARK: - Asset copying

    @discardableResult
    private static func copyAsset(relativePath: String, intoPublic publicDir: URL) -> String? {
        let src = FileStorage.absoluteURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        // Keep file name stable to avoid re-copying on every seed.
        let fileName = src.lastPathComponent
        let dst = publicDir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: dst.path) {
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                return nil
            }
        }
        return fileName
    }

    // MARK: - Seed payload

    private static func buildSeedUserPayload(project: RemotionProject, assets: SeededAssets) -> String {
        let fps = max(1, project.compositionFps)
        let durationFrames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))
        var lines: [String] = []
        lines.append("Project name: \(project.name)")
        lines.append("Duration: \(project.durationSeconds) seconds (= \(durationFrames) frames at \(fps) fps)")
        lines.append("Resolution: \(project.compositionWidth) × \(project.compositionHeight)")
        lines.append("Frame rate: \(fps) fps")
        lines.append("Theme color (hex): \(project.themeColorHex)")
        if !project.text.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.append("Text overlay: \(project.text)")
        }
        if !assets.imageNames.isEmpty {
            lines.append("Images (in public/, reference via staticFile()): \(assets.imageNames.joined(separator: ", "))")
        }
        if let ref = assets.referenceImageName {
            lines.append("Reference image (style guide, do NOT render): \(ref)")
        }
        if let music = assets.musicName {
            lines.append("Music file (in public/): \(music)")
        }
        let userPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userPrompt.isEmpty {
            lines.append("")
            lines.append("User instructions:")
            lines.append(userPrompt)
        }
        lines.append("")
        lines.append("Return the full src/Composition.tsx in a single ```tsx code block.")
        return lines.joined(separator: "\n")
    }

    // MARK: - LLM response extraction

    private struct SeededFile {
        let path: String
        let content: String
    }

    /// Extracts one or more files from the model response. The LLM is instructed to wrap each
    /// file in a fenced code block whose first line is `// FILE: src/path/to/file.tsx`.
    /// If no file marker is found, the first code block is treated as src/Composition.tsx.
    private static func extractFiles(from raw: String) -> [SeededFile] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocks = scanFencedBlocks(in: trimmed)

        var results: [SeededFile] = []
        for block in blocks {
            let (path, body) = stripFileHeader(block)
            results.append(SeededFile(path: path ?? "src/Composition.tsx", content: body))
        }

        if results.isEmpty {
            // No fences — assume the whole reply is Composition.tsx.
            results.append(SeededFile(path: "src/Composition.tsx", content: trimmed))
        }

        // Deduplicate by path, last wins.
        var byPath: [String: String] = [:]
        for r in results { byPath[r.path] = r.content }
        return byPath.map { SeededFile(path: $0.key, content: $0.value) }
    }

    private static func scanFencedBlocks(in text: String) -> [String] {
        var blocks: [String] = []
        var remaining = text[...]
        while let openRange = remaining.range(of: "```") {
            let afterOpen = remaining[openRange.upperBound...]
            // Skip the language tag line (everything up to and including the first newline).
            guard let nlRange = afterOpen.range(of: "\n") else { break }
            let bodyStart = nlRange.upperBound
            let bodyTail = afterOpen[bodyStart...]
            guard let closeRange = bodyTail.range(of: "```") else { break }
            let body = bodyTail[..<closeRange.lowerBound]
            blocks.append(String(body).trimmingCharacters(in: .whitespacesAndNewlines))
            remaining = bodyTail[closeRange.upperBound...]
        }
        return blocks
    }

    private static func stripFileHeader(_ block: String) -> (String?, String) {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, block) }
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        let markers = ["// FILE:", "//FILE:", "// file:", "//file:"]
        for marker in markers {
            if trimmed.uppercased().hasPrefix(marker.uppercased()) {
                let path = trimmed.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
                let rest = lines.dropFirst().joined(separator: "\n")
                return (path.isEmpty ? nil : path, rest.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (nil, block)
    }

    private static let seedSystemPrompt = """
    You are an expert Remotion (React) developer. Author a fresh Remotion project, creatively interpreting the user's brief.

    File layout — ALWAYS split the project into multiple small files, one component per file:
    - src/Composition.tsx — the orchestration entry point. Exports COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT, and MyComposition. Should be LEAN: only Sequence/AbsoluteFill timeline composition that imports sub-components. Avoid inlining helper components here.
    - src/components/<Name>.tsx — every reusable visual element, scene, logo, title card, transition, animation, etc. lives in its own file. One default-exported component per file. Pick descriptive PascalCase filenames.

    Output format — emit one fenced ```tsx code block per file. The FIRST line inside each block MUST be a marker comment of the form:
        // FILE: src/Composition.tsx
        // FILE: src/components/ChatGPTLogo.tsx
    Always include src/Composition.tsx. Add as many src/components/*.tsx files as the design needs (typically 2–6). No prose outside the code blocks.

    Hard requirements:
    - Use the exact frame rate, width, and height provided in the project metadata for COMPOSITION_FPS, COMPOSITION_WIDTH, COMPOSITION_HEIGHT. Set COMPOSITION_DURATION_IN_FRAMES to the requested seconds × COMPOSITION_FPS.
    - Reference assets via staticFile("filename.ext"). Files in public/ are exposed by basename only. Do NOT render the reference image; treat it as a style guide.
    - Allowed imports: only `remotion` and `react` (already in package.json). Use AbsoluteFill, Sequence, Img, Audio, Video, useCurrentFrame, useVideoConfig, interpolate, spring, staticFile, etc. Sub-components import their own primitives directly from `remotion`/`react`.
    - Animate thoughtfully: use interpolate() for fades/slides, spring() for bounces. Avoid plain static frames unless asked.
    - Valid TypeScript JSX only — no markdown fences inside files, no FILE markers other than the first line of each block.
    """
}
#endif
