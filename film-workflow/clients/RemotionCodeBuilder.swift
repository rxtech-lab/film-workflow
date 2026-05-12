#if os(macOS)
import Foundation

enum RemotionCodeBuilderError: LocalizedError {
    case sourceWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceWriteFailed(let message):
            return "Failed to write Composition.tsx: \(message)"
        }
    }
}

struct SeededAssets {
    let imageNames: [String]
    let referenceImageName: String?
    let audioNames: [String]
}

struct RemotionCodeBuilder {

    // MARK: - LLM-driven seed

    /// Copies the project's assets into its public/ dir and returns the asset names
    /// (including subfolder prefix, e.g. "upload/foo.png") the LLM can reference via
    /// staticFile(...).
    ///
    /// Layout:
    /// - public/upload/    — user-uploaded images (project.imagePaths)
    /// - public/reference/ — reference image used as style guide
    /// - public/generated/ — images created by the agent's generate_image tool
    /// - public/audio/     — attached audio files (project.audioFilePaths)
    static func prepareAssets(project: RemotionProject) throws -> SeededAssets {
        let dir = FileStorage.remotionProjectDir(id: project.id)
        let publicDir = dir.appendingPathComponent("public", isDirectory: true)
        let srcDir = dir.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)

        var imageNames: [String] = []
        for relativePath in project.imagePaths {
            if let name = copyAsset(relativePath: relativePath, intoPublic: publicDir, subfolder: "upload") {
                imageNames.append(name)
            }
        }
        var referenceImageName: String?
        if let ref = project.referenceImagePath {
            referenceImageName = copyAsset(relativePath: ref, intoPublic: publicDir, subfolder: "reference")
        }
        var audioNames: [String] = []
        for audio in project.audioFilePaths {
            if let name = copyAsset(relativePath: audio, intoPublic: publicDir, subfolder: "audio") {
                audioNames.append(name)
            }
        }
        return SeededAssets(
            imageNames: imageNames,
            referenceImageName: referenceImageName,
            audioNames: audioNames
        )
    }

    /// Build a no-AI default Composition.tsx scaffold seeded from the project's
    /// settings. Used by MCP `create_project(type="remotion")` so callers get a
    /// ready-to-preview project without round-tripping through the LLM agent.
    static func defaultComposition(project: RemotionProject) -> String {
        let fps = max(1, project.compositionFps)
        let frames = max(1, Int((project.durationSeconds * Double(fps)).rounded()))
        let safeName = project.name
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let theme = project.themeColorHex.isEmpty ? "#1E1E1E" : project.themeColorHex
        return """
        import { AbsoluteFill, useCurrentFrame, interpolate } from "remotion";

        export const COMPOSITION_FPS = \(fps);
        export const COMPOSITION_DURATION_IN_FRAMES = \(frames);
        export const COMPOSITION_WIDTH = \(project.compositionWidth);
        export const COMPOSITION_HEIGHT = \(project.compositionHeight);

        export const MyComposition: React.FC = () => {
          const frame = useCurrentFrame();
          const opacity = interpolate(frame, [0, 30], [0, 1], { extrapolateRight: "clamp" });
          return (
            <AbsoluteFill style={{ backgroundColor: "\(theme)", justifyContent: "center", alignItems: "center" }}>
              <h1 style={{ color: "white", fontFamily: "Helvetica, Arial, sans-serif", opacity }}>\(safeName)</h1>
            </AbsoluteFill>
          );
        };
        """
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
    private static func copyAsset(relativePath: String, intoPublic publicDir: URL, subfolder: String?) -> String? {
        let src = FileStorage.absoluteURL(for: relativePath)
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let fileName = src.lastPathComponent

        let targetDir: URL
        let returnedName: String
        if let sub = subfolder, !sub.isEmpty {
            targetDir = publicDir.appendingPathComponent(sub, isDirectory: true)
            returnedName = "\(sub)/\(fileName)"
            try? FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } else {
            targetDir = publicDir
            returnedName = fileName
        }

        let dst = targetDir.appendingPathComponent(fileName)
        if !FileManager.default.fileExists(atPath: dst.path) {
            do {
                try FileManager.default.copyItem(at: src, to: dst)
            } catch {
                return nil
            }
        }
        return returnedName
    }

}
#endif
