import Foundation

/// Scaffolds Remotion project directories and builds tool environments.
///
/// A project is `src/index.ts` (registers the root), `src/Root.tsx` (one `Main`
/// composition sized by the `COMPOSITION_*` exports of `src/Composition.tsx`),
/// `tsconfig.json`, and `public/` for `staticFile()` assets. MotionSwift compiles it.
@MainActor
final class RemotionRuntime {
    static let shared = RemotionRuntime()

    /// Writes any missing scaffold file; existing files are never overwritten.
    @discardableResult func prepareProjectDirectory(_ directory: URL) throws -> URL {
        try Self.scaffold(at: directory, includeComposition: false)
        return directory
    }

    nonisolated static func scaffold(at directory: URL, includeComposition: Bool = true) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("public"), withIntermediateDirectories: true)
        try fm.createDirectory(at: directory.appendingPathComponent("src"), withIntermediateDirectories: true)
        var files = Template.files
        if includeComposition { files["src/Composition.tsx"] = Template.composition }
        for (path, contents) in files {
            let url = directory.appendingPathComponent(path)
            if !fm.fileExists(atPath: url.path) { try contents.write(to: url, atomically: true, encoding: .utf8) }
        }
    }

    nonisolated static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "0"
        env["CI"] = "1"
        env["BROWSER"] = "none"

        let pathParts = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set(pathParts)
        var merged = pathParts
        for p in extras where !seen.contains(p) {
            merged.append(p); seen.insert(p)
        }
        env["PATH"] = merged.joined(separator: ":")

        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        if env["TMPDIR"] == nil { env["TMPDIR"] = NSTemporaryDirectory() }
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        return env
    }

    private enum Template {
        static let files: [String: String] = [
            "src/index.ts": """
            import { registerRoot } from "remotion";
            import { RemotionRoot } from "./Root";

            registerRoot(RemotionRoot);

            """,
            "src/Root.tsx": """
            import { Composition } from "remotion";
            import { MyComposition, COMPOSITION_FPS, COMPOSITION_DURATION_IN_FRAMES, COMPOSITION_WIDTH, COMPOSITION_HEIGHT } from "./Composition";

            export const RemotionRoot: React.FC = () => {
              return (
                <Composition
                  id="Main"
                  component={MyComposition}
                  durationInFrames={COMPOSITION_DURATION_IN_FRAMES}
                  fps={COMPOSITION_FPS}
                  width={COMPOSITION_WIDTH}
                  height={COMPOSITION_HEIGHT}
                />
              );
            };

            """,
            "tsconfig.json": """
            {
              "compilerOptions": {
                "target": "ES2022",
                "module": "ESNext",
                "moduleResolution": "Bundler",
                "jsx": "react-jsx",
                "strict": true,
                "esModuleInterop": true,
                "skipLibCheck": true,
                "forceConsistentCasingInFileNames": true,
                "isolatedModules": true,
                "allowSyntheticDefaultImports": true
              },
              "include": ["src/**/*"]
            }

            """,
        ]

        static let composition = """
        import { AbsoluteFill } from "remotion";

        export const COMPOSITION_FPS = 30;
        export const COMPOSITION_DURATION_IN_FRAMES = 150;
        export const COMPOSITION_WIDTH = 1920;
        export const COMPOSITION_HEIGHT = 1080;

        export const MyComposition: React.FC = () => {
          return (
            <AbsoluteFill style={{ backgroundColor: "#000000", justifyContent: "center", alignItems: "center" }}>
              <h1 style={{ color: "white", fontFamily: "Helvetica, Arial, sans-serif" }}>Film Studio</h1>
            </AbsoluteFill>
          );
        };

        """
    }
}
