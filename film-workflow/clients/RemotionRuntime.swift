import Foundation
import RxRemotion

/// App compatibility entry point for scaffolding and unrelated tool environments.
@MainActor
final class RemotionRuntime {
    static let shared = RemotionRuntime()
    @discardableResult func prepareProjectDirectory(_ directory: URL) throws -> URL {
        try RemotionEngine.scaffold(at: directory, includeComposition: false)
        return directory
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

}
