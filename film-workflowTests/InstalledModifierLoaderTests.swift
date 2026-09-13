import Foundation
import Testing
import VideoEffectsCore

@testable import film_workflow

@Suite("Installed modifier loader", .serialized)
struct InstalledModifierLoaderTests {
    private static let swipe = """
    {"format":1,"id":"mp.swipe","kind":"transition","name":"Swipe","filter":"CISwipeTransition","progressKey":"inputTime",
     "parameters":[{"id":"angle","title":"Angle","filterKey":"inputAngle","control":{"type":"number","min":0,"max":6.283,"step":0.01},"default":0}]}
    """
    private static let vignette = """
    {"id":"mp.vignette","kind":"effect","name":"Vignette","filter":"CIVignette","parameters":[]}
    """

    private func install(_ kind: MarketplaceKind, id: String, content: String, preview: Bool = false, root: URL) throws {
        let directory = FileStorage.marketplaceItemDir(kind: kind.rawValue, itemID: id, root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: directory.appendingPathComponent("content.json"))
        if preview { try Data([0xFF, 0xD8]).write(to: directory.appendingPathComponent("preview.jpg")) }
        let manifest = InstalledMarketplaceManifest(itemID: id, kind: kind, title: id, category: "test", description: "", contentFilename: "\(id).json", contentRelativePath: "content.json", previewImagePath: preview ? "preview.jpg" : nil, metadata: .init(), installedAt: Date())
        try MarketplaceStore.write(manifest, to: directory)
    }

    @Test("Valid descriptors load, broken and mismatched ones are skipped")
    func loadsValidDescriptors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modifier-loader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try install(.transition, id: "t1", content: Self.swipe, preview: true, root: root)
        try install(.effect, id: "e1", content: Self.vignette, root: root)
        try install(.effect, id: "e2", content: "{ not json", root: root)
        // A transition descriptor filed under effect does not become an effect.
        try install(.effect, id: "e3", content: Self.swipe, root: root)
        try install(.transition, id: "t2", content: Self.swipe.replacingOccurrences(of: "CISwipeTransition", with: "CINope"), root: root)

        let catalog = InstalledModifierLoader.load(root: root)
        #expect(catalog.transitions.map(\.id) == ["mp.swipe"])
        #expect(catalog.effects.map(\.id) == ["mp.vignette"])
        #expect(catalog.previewURLs["mp.swipe"]?.lastPathComponent == "preview.jpg")
        #expect(catalog.previewURLs["mp.vignette"] == nil)
    }

    @Test("Reload publishes into the shared catalog and an empty root clears it")
    func reloadUpdatesCurrent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modifier-loader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root); ModifierCatalog.setInstalled(.empty) }
        try install(.transition, id: "t1", content: Self.swipe, root: root)
        InstalledModifierLoader.reload(root: root)
        #expect(ModifierCatalog.current.transition("mp.swipe") != nil)
        #expect(ModifierCatalog.current.transition("rx.cross-dissolve") != nil)
        try FileManager.default.removeItem(at: root)
        InstalledModifierLoader.reload(root: root)
        #expect(ModifierCatalog.current.transition("mp.swipe") == nil)
    }

    @Test("Descriptor errors are reported in words")
    func descriptorErrors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("modifier-loader-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("content.json")
        try Data(Self.swipe.utf8).write(to: file)
        #expect(throws: MarketplaceError.self) { try InstalledModifierLoader.descriptor(at: file, expecting: .effect) }
        #expect(try InstalledModifierLoader.descriptor(at: file, expecting: .transition).id == "mp.swipe")
        try Data("nope".utf8).write(to: file)
        #expect(throws: MarketplaceError.self) { try InstalledModifierLoader.descriptor(at: file, expecting: .transition) }
    }
}
