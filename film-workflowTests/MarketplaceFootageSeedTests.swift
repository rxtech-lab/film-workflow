import Foundation
import Testing
import VideoEditorCore

@testable import film_workflow

@Suite("Marketplace item from library footage")
@MainActor
struct MarketplaceFootageSeedTests {
    /// The least a take needs to become a `FootageCell`.
    private struct Take: TimelineDraggable {
        let clipSource: ClipSource
        let mediaURL: URL?
    }

    private func cell(_ kind: SourceKind, _ filename: String?) -> FootageCell {
        let take = Take(clipSource: .init(id: UUID().uuidString, kind: kind, displayName: "Take"),
                        mediaURL: filename.map { URL(fileURLWithPath: "/tmp/\($0)") })
        return FootageCell(id: UUID(), title: "v1", subtitle: "", footage: take)
    }

    @Test("A take offers the kind whose content slot accepts its file",
          arguments: [
            (SourceKind.video, "clip.mp4", MarketplaceKind.footage),
            (.video, "clip.mov", .footage),
            (.audio, "take.m4a", .audio),
            (.audio, "take.wav", .audio),
            // Movies are allowed for audio: the upload extracts their track.
            (.audio, "take.mp4", .audio),
            // Stills shelve under footage now; the server decides which shelf.
            (.image, "frame.png", .footage),
            (.image, "frame.jpg", .footage),
            (.image, "frame.webp", .footage),
            // A composition publishes its project, whatever file is in front of it.
            (.remotion, "render.mp4", .remotion),
          ])
    func supportedTakes(kind: SourceKind, filename: String, expected: MarketplaceKind) {
        #expect(cell(kind, filename).marketplaceKind == expected)
    }

    @Test("A take the marketplace has no slot for offers nothing",
          arguments: [
            // Footage only takes movies and stills; a bare audio container is neither.
            (SourceKind.video, "clip.wav" as String?),
            (.image, "frame.tiff"),
            // The marketplace has no kind for captions.
            (.captions, "captions.json"),
            // Nothing rendered yet, so there is no file to upload.
            (.remotion, nil),
            (.video, nil),
          ])
    func unsupportedTakes(kind: SourceKind, filename: String?) {
        #expect(cell(kind, filename).marketplaceKind == nil)
    }

    @Test("The draft is seeded with the item's name and the take's own file")
    func seedCarriesTheFile() throws {
        let take = cell(.video, "harbor-sunrise.mp4")
        let seed = try #require(MarketplaceAuthoringSeed(title: "Harbor sunrise", sourceKind: take.kind, file: take.mediaURL))
        #expect(seed.kind == .footage)
        #expect(seed.title == "Harbor sunrise")
        #expect(seed.contentFile.lastPathComponent == "harbor-sunrise.mp4")
    }

    /// The timeline offers the action before it knows the file, so this is the
    /// only check standing between a clip and the alert it would otherwise hit.
    @Test("The timeline offers the action for every kind that has a slot")
    func timelinePreCheck() {
        #expect(MarketplaceKind.canBeFootage(.video))
        #expect(MarketplaceKind.canBeFootage(.audio))
        #expect(MarketplaceKind.canBeFootage(.remotion))
        #expect(MarketplaceKind.canBeFootage(.image))
        #expect(!MarketplaceKind.canBeFootage(.captions))
    }

    /// A composition's content is an archive of its whole project, which only
    /// the seed host can build, so the file-only initializer must decline it
    /// even though `forFootage` happily names the kind.
    @Test("A composition is not seeded from its rendered file")
    func remotionNeedsItsProject() {
        #expect(MarketplaceKind.forFootage(.remotion, file: URL(fileURLWithPath: "/tmp/render.mp4")) == .remotion)
        #expect(MarketplaceKind.remotion.seedsFromFileAlone == false)
        #expect(MarketplaceKind.footage.seedsFromFileAlone)
        #expect(MarketplaceAuthoringSeed(title: "Cold open", sourceKind: .remotion, file: URL(fileURLWithPath: "/tmp/render.mp4")) == nil)
    }

    @Test("A still seeds a footage draft carrying the image itself")
    func stillSeed() throws {
        let take = cell(.image, "harbor-dawn.png")
        let seed = try #require(MarketplaceAuthoringSeed(title: "Harbor dawn", sourceKind: take.kind, file: take.mediaURL))
        #expect(seed.kind == .footage)
        #expect(seed.contentFile.lastPathComponent == "harbor-dawn.png")
    }

    @Test("Nothing is seeded without a file, whatever the kind")
    func noFileNoSeed() {
        #expect(MarketplaceAuthoringSeed(title: "Harbor sunrise", sourceKind: .video, file: nil) == nil)
    }

}
