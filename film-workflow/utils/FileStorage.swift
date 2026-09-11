import Foundation

/// App-wide locations that are not part of any film.
///
/// Everything a film generates lives inside its `.rxfilmstudio` package and is
/// addressed through `ProjectStorage`. What stays here is shared by every film:
/// the Remotion runtime (bun and the vendored `node_modules`), Whisper models,
/// the agent thread store, scratch space, and a couple of JSON caches.
nonisolated struct FileStorage {
    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rxlab.film-workflow", isDirectory: true)
    }

    /// WhisperKit's `downloadBase`. Models land in
    /// `whisper/models/argmaxinc/whisperkit-coreml/<variant>/`.
    static var whisperModelsDir: URL {
        appSupportURL.appendingPathComponent("whisper", isDirectory: true)
    }

    /// Scratch space for multipart request bodies, audio chunks, and format
    /// conversions. Cleared on launch — nothing here survives a restart.
    static var tempDir: URL {
        appSupportURL.appendingPathComponent("tmp", isDirectory: true)
    }

    /// Agent threads and messages, which span films.
    static var agentStoreURL: URL {
        appSupportURL.appendingPathComponent("Agent.store")
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: appSupportURL, withIntermediateDirectories: true)
        try? fm.createDirectory(at: whisperModelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Removes everything in `tempDir` and recreates it. Called at launch:
    /// chunked audio and multipart bodies can be hundreds of megabytes, and a
    /// crash mid-transcription would otherwise leak them permanently.
    static func clearTemp() {
        let fm = FileManager.default
        try? fm.removeItem(at: tempDir)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    /// Returns a unique path inside `tempDir`. The file is not created.
    static func temporaryFileURL(extension ext: String) -> URL {
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let name = trimmed.isEmpty ? UUID().uuidString : UUID().uuidString + "." + trimmed
        return tempDir.appendingPathComponent(name)
    }
}
