#if os(macOS)
import Foundation

/// Project-tree introspection shared by the agent's `list_files` tool and the source viewer.
/// Walks `src/` and `public/` plus the small set of root config files; skips heavy or
/// generated dirs (node_modules, .agent-stills, build outputs).
enum RemotionProjectFiles {

    private static let includeRoots: [String] = ["src", "public"]
    private static let includeRootFiles: [String] = ["package.json", "tsconfig.json", "remotion.config.ts"]
    private static let excludePathFragments: [String] = [
        "/node_modules/", "/.agent-stills/", "/.git/", "/dist/", "/build/", "/.next/"
    ]

    /// Returns relative paths (forward slashes), sorted alphabetically.
    static func list(projectDir: URL) -> [String] {
        let fm = FileManager.default
        var results: [String] = []
        let projectPath = projectDir.standardizedFileURL.path

        for name in includeRootFiles {
            let url = projectDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                results.append(name)
            }
        }

        for root in includeRoots {
            let rootURL = projectDir.appendingPathComponent(root, isDirectory: true)
            guard fm.fileExists(atPath: rootURL.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                let resolved = url.standardizedFileURL.path
                if excludePathFragments.contains(where: resolved.contains) { continue }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values?.isSymbolicLink == true { continue }
                guard values?.isRegularFile == true else { continue }
                if resolved.hasPrefix(projectPath + "/") {
                    let relative = String(resolved.dropFirst(projectPath.count + 1))
                    results.append(relative)
                }
            }
        }

        return results.sorted()
    }
}
#endif
