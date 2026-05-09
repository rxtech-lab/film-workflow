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

    /// Asks the LLM to write src/Composition.tsx from scratch using the form fields and the user prompt.
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

        let extracted = extractTSX(from: raw)
        guard !extracted.isEmpty else { throw RemotionCodeBuilderError.noResponse }

        let dir = FileStorage.remotionProjectDir(id: project.id)
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try writeComposition(source: extracted, to: srcDir)
        return extracted
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

    // MARK: - LLM editing

    static func applyEdit(
        project: RemotionProject,
        userInstruction: String,
        history: [RemotionMessage],
        config: AppConfig
    ) async throws -> String {
        var systemPrompt = editSystemPrompt
        let standingPrompt = project.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !standingPrompt.isEmpty {
            systemPrompt += "\n\nProject brief (keep edits consistent with this):\n\(standingPrompt)"
        }

        var messages: [OpenAIChatMessage] = []
        messages.append(OpenAIChatMessage(role: "system", content: systemPrompt))

        let priorTurns = history.suffix(20)
        for msg in priorTurns where msg.role != RemotionMessageRole.system.rawValue {
            messages.append(OpenAIChatMessage(role: msg.role, content: msg.content))
        }

        let userPayload = """
        Current src/Composition.tsx:

        ```tsx
        \(project.compositionSource)
        ```

        Instruction: \(userInstruction)

        Return ONLY the full updated contents of src/Composition.tsx in a single ```tsx code block.
        """

        messages.append(OpenAIChatMessage(role: "user", content: userPayload))

        let raw = try await OpenAIClient.chat(
            messages: messages,
            endpoint: config.openAIEndpoint,
            apiKey: config.openAIKey,
            model: config.openAIModel
        )

        let extracted = extractTSX(from: raw)
        guard !extracted.isEmpty else {
            throw RemotionCodeBuilderError.noResponse
        }
        return extracted
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
        let durationFrames = max(1, Int((project.durationSeconds * 30).rounded()))
        var lines: [String] = []
        lines.append("Project name: \(project.name)")
        lines.append("Duration: \(project.durationSeconds) seconds (= \(durationFrames) frames at 30 fps)")
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

    private static func extractTSX(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Look for ```tsx ... ``` or ```ts ... ``` or ``` ... ```
        let patterns = ["```tsx\n", "```typescript\n", "```ts\n", "```jsx\n", "```\n"]
        for pat in patterns {
            if let startRange = trimmed.range(of: pat) {
                let afterStart = trimmed[startRange.upperBound...]
                if let endRange = afterStart.range(of: "```") {
                    return String(afterStart[..<endRange.lowerBound])
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        // No fence — assume whole body is the TSX.
        return trimmed
    }

    private static let editSystemPrompt = """
    You are an expert Remotion (React) developer. You edit the file src/Composition.tsx of a Remotion project.

    Rules:
    - Always return the FULL contents of src/Composition.tsx in a single ```tsx code block. No prose outside the code block.
    - Preserve and export: COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT, and MyComposition. The Root.tsx imports these by name.
    - Reference local assets via staticFile("filename.ext"). Files placed under public/ are exposed by their basename only.
    - Use Remotion primitives: AbsoluteFill, Sequence, Img, Audio, Video, useCurrentFrame, useVideoConfig, interpolate, spring.
    - Do not import any package not already in package.json (only react, react-dom, remotion).
    - The file must be valid TypeScript JSX — no markdown, no commentary in the code.
    """

    private static let seedSystemPrompt = """
    You are an expert Remotion (React) developer. Author the file src/Composition.tsx for a fresh Remotion project, creatively interpreting the user's brief.

    Hard requirements:
    - Output ONLY the full contents of src/Composition.tsx in a single ```tsx code block. No prose outside the block.
    - Export these exact symbols: COMPOSITION_FPS (number), COMPOSITION_DURATION_IN_FRAMES (number), COMPOSITION_WIDTH (number), COMPOSITION_HEIGHT (number), and MyComposition (React component). The Root.tsx imports these by name.
    - Use 30 for COMPOSITION_FPS, 1920 for COMPOSITION_WIDTH, 1080 for COMPOSITION_HEIGHT. Set COMPOSITION_DURATION_IN_FRAMES to the requested seconds × 30.
    - Reference assets via staticFile("filename.ext"). Files in public/ are exposed by basename only. Do NOT render the reference image; treat it as a style guide.
    - Allowed imports: only `remotion` and `react` (already in package.json). Use AbsoluteFill, Sequence, Img, Audio, Video, useCurrentFrame, useVideoConfig, interpolate, spring, staticFile, etc.
    - Animate thoughtfully: use interpolate() for fades/slides, spring() for bounces. Avoid plain static frames unless asked.
    - Valid TypeScript JSX only — no comments outside the code, no markdown inside the code.
    """
}
#endif
