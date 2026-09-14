import Foundation
import Testing

@testable import film_workflow

@Suite("Remotion project archives")
struct RemotionProjectArchiveTests {
    private let fm = FileManager.default

    private func scratch() -> URL {
        fm.temporaryDirectory.appendingPathComponent("RemotionArchiveTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A project tree with the things the walk is meant to skip alongside the
    /// things it is meant to keep.
    private func project() throws -> URL {
        let dir = scratch()
        try fm.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("public/upload"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("node_modules/remotion"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent(".agent-stills/run-1"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data("export const Composition = () => null;\n".utf8).write(to: dir.appendingPathComponent("src/Composition.tsx"))
        try Data("export const Root = () => null;\n".utf8).write(to: dir.appendingPathComponent("src/Root.tsx"))
        try Data("{\"name\":\"demo\"}\n".utf8).write(to: dir.appendingPathComponent("package.json"))
        try Data("{}\n".utf8).write(to: dir.appendingPathComponent("tsconfig.json"))
        try Data("image".utf8).write(to: dir.appendingPathComponent("public/upload/shot.png"))
        try Data("huge".utf8).write(to: dir.appendingPathComponent("node_modules/remotion/index.js"))
        try Data("still".utf8).write(to: dir.appendingPathComponent(".agent-stills/run-1/frame-0.png"))
        try Data("built".utf8).write(to: dir.appendingPathComponent("dist/bundle.js"))
        return dir
    }

    private func descriptor() -> RemotionProjectArchive.Descriptor {
        .init(name: "Cold open", prompt: "Open on black", compositionWidth: 1920, compositionHeight: 1080,
              compositionFps: 30, durationSeconds: 8)
    }

    @Test("The archive carries the source and leaves the heavy directories behind")
    func roundTrip() throws {
        let source = try project()
        defer { try? fm.removeItem(at: source) }
        let zip = source.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zip) }
        try RemotionProjectArchive.write(project: source, descriptor: descriptor(), to: zip)

        let unpacked = scratch()
        defer { try? fm.removeItem(at: unpacked) }
        let read = try RemotionProjectArchive.read(archive: zip, into: unpacked)

        #expect(read == descriptor())
        #expect(fm.fileExists(atPath: unpacked.appendingPathComponent("src/Composition.tsx").path))
        #expect(fm.fileExists(atPath: unpacked.appendingPathComponent("src/Root.tsx").path))
        #expect(fm.fileExists(atPath: unpacked.appendingPathComponent("public/upload/shot.png").path))
        #expect(fm.fileExists(atPath: unpacked.appendingPathComponent("package.json").path))
        #expect(fm.fileExists(atPath: unpacked.appendingPathComponent(RemotionProjectArchive.descriptorName).path))
        // What `RemotionProjectFiles.list` skips must never reach a buyer.
        #expect(!fm.fileExists(atPath: unpacked.appendingPathComponent("node_modules").path))
        #expect(!fm.fileExists(atPath: unpacked.appendingPathComponent(".agent-stills").path))
        #expect(!fm.fileExists(atPath: unpacked.appendingPathComponent("dist").path))
    }

    @Test("Validation reads the descriptor without keeping the files")
    func validates() throws {
        let source = try project()
        defer { try? fm.removeItem(at: source) }
        let zip = source.deletingLastPathComponent().appendingPathComponent("out-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: zip) }
        try RemotionProjectArchive.write(project: source, descriptor: descriptor(), to: zip)
        #expect(try RemotionProjectArchive.validate(archive: zip).prompt == "Open on black")
    }

    @Test("A project with nothing in it is refused rather than published empty")
    func refusesEmpty() throws {
        let empty = scratch()
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: empty) }
        #expect(throws: RemotionProjectArchive.ArchiveError.empty) {
            try RemotionProjectArchive.write(project: empty, descriptor: descriptor(),
                                             to: empty.appendingPathComponent("out.zip"))
        }
    }

    @Test("A project larger than the slot is refused before anything is uploaded")
    func refusesOversized() throws {
        let source = try project()
        defer { try? fm.removeItem(at: source) }
        #expect(throws: (any Error).self) {
            // One byte of headroom is less than the tree needs.
            try RemotionProjectArchive.write(project: source, descriptor: descriptor(),
                                             to: source.deletingLastPathComponent().appendingPathComponent("out.zip"),
                                             limitBytes: 1)
        }
    }

    // MARK: - Hostile archives

    /// Zips whatever tree `build` leaves behind, without going through `write`,
    /// so the archive can contain things publishing would never produce.
    private func hostileArchive(_ build: (URL) throws -> Void) throws -> URL {
        let staging = scratch()
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try build(staging)
        let zip = fm.temporaryDirectory.appendingPathComponent("hostile-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--norsrc", "--noextattr", staging.path, zip.path]
        try process.run()
        process.waitUntilExit()
        return zip
    }

    private func writeValidBase(_ root: URL) throws {
        try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try Data("export const Composition = () => null;\n".utf8).write(to: root.appendingPathComponent("src/Composition.tsx"))
        let json = JSONEncoder()
        try json.encode(descriptor()).write(to: root.appendingPathComponent(RemotionProjectArchive.descriptorName))
    }

    @Test("An archive reaching outside its own tree is refused")
    func refusesEscapingEntries() throws {
        let zip = try hostileArchive { root in
            try writeValidBase(root)
            // A symlink is how an archive escapes the directory it unpacks into.
            try fm.createSymbolicLink(at: root.appendingPathComponent("public"),
                                      withDestinationURL: URL(fileURLWithPath: "/etc"))
        }
        defer { try? fm.removeItem(at: zip) }
        #expect(throws: (any Error).self) { try RemotionProjectArchive.validate(archive: zip) }
    }

    @Test("An archive carrying anything but a Remotion project is refused")
    func refusesForeignRoots() throws {
        let zip = try hostileArchive { root in
            try writeValidBase(root)
            try Data("#!/bin/sh\nrm -rf /\n".utf8).write(to: root.appendingPathComponent("postinstall.sh"))
        }
        defer { try? fm.removeItem(at: zip) }
        #expect(throws: (any Error).self) { try RemotionProjectArchive.validate(archive: zip) }
    }

    @Test("An archive without a composition or a descriptor is refused")
    func refusesIncomplete() throws {
        let noComposition = try hostileArchive { root in
            let json = JSONEncoder()
            try json.encode(descriptor()).write(to: root.appendingPathComponent(RemotionProjectArchive.descriptorName))
        }
        defer { try? fm.removeItem(at: noComposition) }
        #expect(throws: (any Error).self) { try RemotionProjectArchive.validate(archive: noComposition) }

        let noDescriptor = try hostileArchive { root in
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("export const Composition = () => null;\n".utf8).write(to: root.appendingPathComponent("src/Composition.tsx"))
        }
        defer { try? fm.removeItem(at: noDescriptor) }
        #expect(throws: (any Error).self) { try RemotionProjectArchive.validate(archive: noDescriptor) }
    }

    @Test("An unreadable descriptor is refused rather than silently defaulted")
    func refusesMalformedDescriptor() throws {
        let zip = try hostileArchive { root in
            try fm.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
            try Data("export const Composition = () => null;\n".utf8).write(to: root.appendingPathComponent("src/Composition.tsx"))
            try Data("not json".utf8).write(to: root.appendingPathComponent(RemotionProjectArchive.descriptorName))
        }
        defer { try? fm.removeItem(at: zip) }
        #expect(throws: RemotionProjectArchive.ArchiveError.malformedDescriptor) {
            try RemotionProjectArchive.validate(archive: zip)
        }
    }
}
