import Foundation
import SwiftData
import Testing
import VideoEditorCore

@testable import film_workflow

/// Installed marketplace items play in the library the way this film's own
/// footage does, and an item added from the marketplace is never offered
/// back to it.
@Suite("Library marketplace playback", .serialized)
@MainActor
struct LibraryMarketplacePlaybackTests {
    private func manifest(_ kind: MarketplaceKind, id: String = UUID().uuidString, title: String = "Item",
                          filename: String = "content.mp4", metadata: MarketplaceItemMetadata = .init()) -> InstalledMarketplaceManifest {
        InstalledMarketplaceManifest(itemID: id, kind: kind, title: title, category: "test", description: "",
                                     contentFilename: filename, contentRelativePath: filename, previewImagePath: "preview.jpg",
                                     metadata: metadata, installedAt: Date())
    }

    private func row(_ manifest: InstalledMarketplaceManifest) -> LibraryMarketplaceRow {
        LibraryMarketplaceRow(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/marketplace-playback/\(manifest.itemID)"))
    }

    @Test("An installed item reads as the kind of footage its file actually is",
          arguments: [
            (MarketplaceKind.footage, "video" as String?, SourceKind?.some(.video)),
            (.footage, "image", .image),
            // Footage predating media types was only ever video.
            (.footage, nil, .video),
            (.audio, nil, .audio),
            (.soundEffect, nil, .audio),
            // A composition ships an archive of its project, not media.
            (.remotion, nil, nil),
            (.font, nil, nil),
            (.projectTemplate, nil, nil),
          ])
    func sourceKinds(kind: MarketplaceKind, mediaType: String?, expected: SourceKind?) {
        #expect(row(manifest(kind, metadata: .init(mediaType: mediaType))).sourceKind == expected)
    }

    @Test("A clip previews and scrubs off its own file, the way a library take does")
    func clipIsPlayable() throws {
        let row = row(manifest(.footage, id: "harbor", title: "Harbor sunrise", metadata: .init(durationSeconds: 12.5, width: 1920, height: 1080, mediaType: "video")))
        let cell = try #require(row.footage)
        #expect(cell.kind == .video)
        #expect(cell.mediaURL == row.mediaURL)
        #expect(cell.duration == 12.5)
        #expect(cell.drag.naturalWidth == 1920)
        #expect(cell.drag.naturalHeight == 1080)
        // What makes the filmstrip take a hover and a click.
        #expect(cell.previewSource?.canScrub == true)
        #expect(cell.previewSource?.isTemporal == true)
    }

    @Test("A still holds one frame: it has a preview but nothing to scrub")
    func stillIsNotScrubbable() throws {
        let cell = try #require(row(manifest(.footage, filename: "frame.png", metadata: .init(mediaType: "image"))).footage)
        #expect(cell.kind == .image)
        #expect(cell.previewSource?.canScrub == false)
        #expect(cell.previewSource?.isTemporal == false)
    }

    @Test("Music draws a waveform strip and plays")
    func audioIsPlayable() throws {
        let cell = try #require(row(manifest(.audio, filename: "track.mp3", metadata: .init(durationSeconds: 96))).footage)
        #expect(cell.kind == .audio)
        #expect(cell.previewSource?.canScrub == true)
        #expect(cell.duration == 96)
    }

    @Test("An item with no media of its own offers no preview at all")
    func archiveHasNoFootage() {
        let remotion = row(manifest(.remotion, filename: "composition.zip"))
        #expect(remotion.footage == nil)
        #expect(remotion.preview == nil)
        // It keeps the held poster the card drew before.
        #expect(remotion.isStill)
    }

    @Test("A card's identity is stable across launches, and distinct per item")
    func cellIdentityIsStable() throws {
        let first = try #require(row(manifest(.footage, id: "harbor")).footage)
        let again = try #require(row(manifest(.footage, id: "harbor")).footage)
        let other = try #require(row(manifest(.footage, id: "skyline")).footage)
        #expect(first.id == again.id)
        #expect(first.id != other.id)
        // A server that names items by UUID keeps that name.
        let uuid = UUID()
        #expect(try #require(row(manifest(.footage, id: uuid.uuidString)).footage).id == uuid)
    }

    // MARK: - What the viewer shows

    @Test("A click holds an installed item in the viewer; a pass over another outranks it")
    func previewRouting() throws {
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "marketplace-preview-\(UUID().uuidString)")!)
        let harbor = try #require(row(manifest(.footage, id: "harbor", title: "Harbor sunrise", metadata: .init(durationSeconds: 10, mediaType: "video"))).preview)
        let skyline = try #require(row(manifest(.footage, id: "skyline", title: "City skyline", metadata: .init(durationSeconds: 10, mediaType: "video"))).preview)

        #expect(state.marketplacePreview == nil)
        state.selectMarketplace(harbor, fraction: 0.25)
        #expect(state.marketplaceSelection?.rowID == "harbor")
        #expect(state.marketplacePreview?.name == "Harbor sunrise")
        // A click commits the frame even while the file is still opening.
        #expect(state.footagePlayer.loadedCellID == nil)

        state.skimMarketplace(skyline, fraction: 0.5)
        #expect(state.marketplacePreview?.rowID == "skyline")
        #expect(state.marketplacePreview?.skimFraction == 0.5)
        // The held card is untouched and comes back when the pointer leaves.
        #expect(state.marketplaceSelection?.rowID == "harbor")
        state.endMarketplaceSkim()
        #expect(state.marketplacePreview?.rowID == "harbor")
        #expect(state.marketplacePreview?.skimFraction == nil)
    }

    @Test("Picking something of this film's own hands the viewer back")
    func filmSelectionWins() throws {
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "marketplace-preview-\(UUID().uuidString)")!)
        let harbor = try #require(row(manifest(.footage, id: "harbor", metadata: .init(mediaType: "video"))).preview)

        state.selectMarketplace(harbor, fraction: 0)
        state.select(LibraryItemID(kind: .imported, id: UUID()))
        #expect(state.marketplacePreview == nil)

        state.selectMarketplace(harbor, fraction: 0)
        // Leaving the tab, or clicking between the cards, does the same.
        state.clearMarketplacePreview()
        #expect(state.marketplacePreview == nil)
    }

    @Test("A position that is not a number moves nothing")
    func skimIgnoresNonsense() throws {
        let state = EditorWindowState(defaults: UserDefaults(suiteName: "marketplace-preview-\(UUID().uuidString)")!)
        let harbor = try #require(row(manifest(.footage, id: "harbor", metadata: .init(mediaType: "video"))).preview)
        state.skimMarketplace(harbor, fraction: .nan)
        #expect(state.marketplacePreview == nil)
    }

    // MARK: - Publishing what came from the marketplace

    private func temporaryPackage() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryMarketplacePlaybackTests-\(UUID().uuidString)")
            .appendingPathExtension("rxfilmstudio")
    }

    private func index(_ document: ProjectDocument) throws -> LibraryIndex {
        let context = document.container.mainContext
        return LibraryIndex(remotions: try context.fetch(FetchDescriptor<RemotionProject>()),
                            imported: try context.fetch(FetchDescriptor<ImportedAsset>()))
    }

    @Test("Footage added from the marketplace is never offered back to it")
    func installedFootageIsNotPublishable() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let clip = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-\(UUID().uuidString).mp4")
        try Data(repeating: 0, count: 64).write(to: clip)
        defer { try? FileManager.default.removeItem(at: clip) }

        let added = try await MarketplaceInstaller.addToFilm(
            manifest(.footage, id: "harbor", title: "Harbor sunrise", filename: "harbor.mp4", metadata: .init(mediaType: "video")),
            contentURL: clip, document: document)

        let index = try index(document)
        #expect(index.isFromMarketplace(added))
        let row = try #require(index.rows().first { $0.id == added })
        #expect(row.isFromMarketplace)
        await document.close()
    }

    @Test("A file the user imported themselves still is")
    func ownFootageStaysPublishable() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let asset = ImportedAsset(name: "My clip", kind: .video, originalPath: "/tmp/mine.mp4")
        context.insert(asset)
        try context.save()

        let index = try index(document)
        let item = LibraryItemID(kind: .imported, id: asset.id)
        #expect(!index.isFromMarketplace(item))
        #expect(try #require(index.rows().first { $0.id == item }).isFromMarketplace == false)
        await document.close()
    }

    @Test("A composition unpacked from the marketplace is not offered back either")
    func installedCompositionIsNotPublishable() async throws {
        let url = temporaryPackage()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try ProjectDocument.create(at: url)
        let context = document.container.mainContext
        let installed = RemotionProject(name: "Cold open")
        installed.marketplaceItemId = "intro"
        let own = RemotionProject(name: "My titles")
        context.insert(installed)
        context.insert(own)
        try context.save()

        let index = try index(document)
        #expect(index.isFromMarketplace(LibraryItemID(kind: .remotion, id: installed.id)))
        #expect(!index.isFromMarketplace(LibraryItemID(kind: .remotion, id: own.id)))
        // Kinds the installer never creates can never have come from there.
        #expect(!index.isFromMarketplace(LibraryItemID(kind: .sequence, id: UUID())))
        await document.close()
    }
}
