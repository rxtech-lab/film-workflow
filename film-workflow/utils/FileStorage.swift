import Foundation

struct FileStorage {
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

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: generatedDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
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

    static func deleteFile(at relativePath: String) {
        let url = absoluteURL(for: relativePath)
        try? FileManager.default.removeItem(at: url)
    }
}
