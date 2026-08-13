import Foundation

nonisolated struct FileStorage {
    static var appSupportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.rxlab.film-workflow", isDirectory: true)
    }

    static var generatedDir: URL {
        appSupportURL.appendingPathComponent("generated", isDirectory: true)
    }

    static var imagesDir: URL {
        appSupportURL.appendingPathComponent("images", isDirectory: true)
    }

    /// Generated video clips. Poster frames live in `images/` alongside every
    /// other still rather than here.
    static var videosDir: URL {
        appSupportURL.appendingPathComponent("videos", isDirectory: true)
    }

    /// Audio imported for captioning. Caption projects that own their audio
    /// keep it here; narrative-sourced projects point at `generated/` instead.
    static var captionsDir: URL {
        appSupportURL.appendingPathComponent("captions", isDirectory: true)
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

    static var remotionRoot: URL {
        appSupportURL.appendingPathComponent("remotion", isDirectory: true)
    }

    static var remotionProjectsDir: URL {
        remotionRoot.appendingPathComponent("projects", isDirectory: true)
    }

    static func remotionProjectDir(id: UUID) -> URL {
        remotionProjectsDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: generatedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: videosDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: captionsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: whisperModelsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: remotionRoot, withIntermediateDirectories: true)
        try? fm.createDirectory(at: remotionProjectsDir, withIntermediateDirectories: true)
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

    static func saveAudio(_ data: Data, extension ext: String) throws -> String {
        let filename = UUID().uuidString + "." + ext
        let url = generatedDir.appendingPathComponent(filename)
        try data.write(to: url)
        return "generated/" + filename
    }

    static func absoluteURL(for relativePath: String) -> URL {
        appSupportURL.appendingPathComponent(relativePath)
    }

    static func copyImage(from sourceURL: URL) throws -> String {
        let filename = UUID().uuidString + "." + sourceURL.pathExtension
        let dest = imagesDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return "images/" + filename
    }

    static func saveImage(_ data: Data, fileExtension: String = "jpg") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = ext.isEmpty ? "jpg" : ext
        let filename = UUID().uuidString + "." + finalExt
        let dest = imagesDir.appendingPathComponent(filename)
        try data.write(to: dest)
        return "images/" + filename
    }

    static func saveVideo(_ data: Data, fileExtension: String = "mp4") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = ext.isEmpty ? "mp4" : ext
        let filename = UUID().uuidString + "." + finalExt
        let dest = videosDir.appendingPathComponent(filename)
        try data.write(to: dest)
        return "videos/" + filename
    }

    /// Moves a freshly downloaded clip into `videos/`, returning its relative
    /// path. A move rather than a copy because the source is the temp file
    /// `URLSession.download` hands back, and a generated video is large enough
    /// that reading it into memory to re-write it would be wasteful.
    static func importVideo(movingFrom sourceURL: URL, fileExtension: String = "mp4") throws -> String {
        let ext = fileExtension.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = ext.isEmpty ? "mp4" : ext
        let filename = UUID().uuidString + "." + finalExt
        let dest = videosDir.appendingPathComponent(filename)
        let fm = FileManager.default
        do {
            try fm.moveItem(at: sourceURL, to: dest)
        } catch {
            // Falls back for the cross-volume case, where a move is not atomic
            // and Foundation refuses it.
            try fm.copyItem(at: sourceURL, to: dest)
            try? fm.removeItem(at: sourceURL)
        }
        return "videos/" + filename
    }

    /// Copies audio the user picked into `captions/`, returning its relative
    /// path. Callers are responsible for the security-scoped resource dance
    /// around `.fileImporter` URLs.
    static func importAudio(from sourceURL: URL) throws -> String {
        let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
        let filename = UUID().uuidString + "." + ext
        let dest = captionsDir.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: dest)
        return "captions/" + filename
    }

    static func saveCaptionFile(_ data: Data, extension ext: String) throws -> String {
        let trimmed = ext.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        let finalExt = trimmed.isEmpty ? "vtt" : trimmed
        let filename = UUID().uuidString + "." + finalExt
        let dest = captionsDir.appendingPathComponent(filename)
        try data.write(to: dest)
        return "captions/" + filename
    }

    static func deleteFile(at relativePath: String) {
        let url = absoluteURL(for: relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
