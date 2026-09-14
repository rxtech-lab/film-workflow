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
          ])
    func supportedTakes(kind: SourceKind, filename: String, expected: MarketplaceKind) {
        #expect(cell(kind, filename).marketplaceKind == expected)
    }

    @Test("A take the marketplace has no slot for offers nothing",
          arguments: [
            // Footage only takes movies; a bare audio container is not one.
            (SourceKind.video, "clip.wav" as String?),
            // The marketplace has no kind for a still or for captions.
            (.image, "frame.png"),
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
        #expect(!MarketplaceKind.canBeFootage(.image))
        #expect(!MarketplaceKind.canBeFootage(.captions))
    }

    @Test("Nothing is seeded without a file, whatever the kind")
    func noFileNoSeed() {
        #expect(MarketplaceAuthoringSeed(title: "Harbor sunrise", sourceKind: .video, file: nil) == nil)
    }

}
