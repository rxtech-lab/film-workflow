import Foundation

/// Finds developer CLIs (`claude`, `codex`) that the user installed themselves.
///
/// A GUI app launched from Finder inherits a thin launchd environment whose
/// `PATH` is `/usr/bin:/bin:/usr/sbin:/sbin` — none of the places npm, Homebrew
/// or nvm install to. `RemotionRuntime.enrichedEnvironment()` already backfills
/// the fixed directories for the embedded Bun runtime; this adds the login-shell
/// fallback, which is the only way to find an nvm-managed install whose path
/// contains a version number.
nonisolated enum CaptionCLILocator {

    /// Directories checked before falling back to a login shell.
    static var wellKnownDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.claude/local",
        ]
    }

    /// Absolute path to `name`, or nil when it isn't installed.
    ///
    /// Callers should cache the result — the login-shell fallback spawns a
    /// process and takes tens of milliseconds.
    static func find(_ name: String) -> String? {
        guard !name.isEmpty else { return nil }
        #if os(macOS)
            let fileManager = FileManager.default

            for directory in wellKnownDirectories {
                let candidate = (directory as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }

            // Anything already on our PATH, including the enriched entries.
            let path = RemotionRuntime.enrichedEnvironment()["PATH"] ?? ""
            for directory in path.split(separator: ":") {
                let candidate = (String(directory) as NSString).appendingPathComponent(name)
                if fileManager.isExecutableFile(atPath: candidate) { return candidate }
            }

            return loginShellLookup(name)
        #else
            return nil
        #endif
    }

    #if os(macOS)
        /// Asks an interactive login shell where the binary is.
        ///
        /// `-ilc` so `.zshrc` runs and nvm/mise/asdf shims get set up;
        /// `whence -p` skips aliases and functions, which would otherwise
        /// return something we can't exec.
        private static func loginShellLookup(_ name: String) -> String? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-ilc", "whence -p \(name)"]
            process.environment = RemotionRuntime.enrichedEnvironment()

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }

            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // A shell function or alias resolves to something that isn't a path.
            guard output.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: output) else { return nil }
            return output
        }
    #endif
}
