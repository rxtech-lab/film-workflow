import Foundation
import Testing

@testable import film_workflow

@Suite("Remotion source hasher")
struct RemotionSourceHasherTests {
    private func makeProject() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemotionHasher-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("public/upload"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/remotion"), withIntermediateDirectories: true)
        try "export const A = 1".write(to: dir.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        try "{}".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try Data([1, 2, 3]).write(to: dir.appendingPathComponent("public/upload/a.png"))
        try "junk".write(to: dir.appendingPathComponent("node_modules/remotion/index.js"), atomically: true, encoding: .utf8)
        try "log".write(to: dir.appendingPathComponent("render.log"), atomically: true, encoding: .utf8)
        return dir
    }

    @Test("Stable across calls, sensitive to source, settings and assets, blind to logs and node_modules")
    func hashBehaviour() throws {
        let dir = try makeProject()
        defer { try? FileManager.default.removeItem(at: dir) }

        let base = try RemotionSourceHasher.hash(projectDir: dir, width: 1920, height: 1080, fps: 30)
        #expect(base.count == 64)
        #expect(try RemotionSourceHasher.hash(projectDir: dir, width: 1920, height: 1080, fps: 30) == base)
        #expect(try RemotionSourceHasher.hash(projectDir: dir, width: 1280, height: 720, fps: 30) != base)

        try "more".write(to: dir.appendingPathComponent("render.log"), atomically: true, encoding: .utf8)
        try "changed".write(to: dir.appendingPathComponent("node_modules/remotion/index.js"), atomically: true, encoding: .utf8)
        #expect(try RemotionSourceHasher.hash(projectDir: dir, width: 1920, height: 1080, fps: 30) == base)

        try "export const A = 2".write(to: dir.appendingPathComponent("src/Composition.tsx"), atomically: true, encoding: .utf8)
        let edited = try RemotionSourceHasher.hash(projectDir: dir, width: 1920, height: 1080, fps: 30)
        #expect(edited != base)

        try Data([1, 2, 3, 4]).write(to: dir.appendingPathComponent("public/upload/a.png"))
        #expect(try RemotionSourceHasher.hash(projectDir: dir, width: 1920, height: 1080, fps: 30) != edited)
    }
}
