import Foundation
import Testing

@testable import film_workflow

@Suite("Marketplace media types and resolution")
struct MarketplaceMediaTypeTests {
    private func item(_ kind: MarketplaceKind, filename: String? = nil, metadata: MarketplaceItemMetadata = .init()) -> MarketplaceItem {
        MarketplaceItem(id: "x", kind: kind, category: "c", title: "T", contentFilename: filename, metadata: metadata)
    }

    private func manifest(_ kind: MarketplaceKind, metadata: MarketplaceItemMetadata = .init()) -> InstalledMarketplaceManifest {
        InstalledMarketplaceManifest(itemID: "x", kind: kind, title: "T", category: "c", description: "",
                                     contentFilename: "content", contentRelativePath: "content",
                                     previewImagePath: nil, metadata: metadata, installedAt: Date())
    }

    @Test("Buckets follow the long-side names people expect")
    func buckets() {
        #expect(MarketplaceResolution.bucket(width: 3840, height: 2160) == "4K")
        #expect(MarketplaceResolution.bucket(width: 2560, height: 1440) == "1440p")
        #expect(MarketplaceResolution.bucket(width: 1920, height: 1080) == "1080p")
        #expect(MarketplaceResolution.bucket(width: 1280, height: 720) == "720p")
        #expect(MarketplaceResolution.bucket(width: 640, height: 480) == "SD")
    }

    /// The short side is what is measured, so a vertical clip is not promoted
    /// a tier above the landscape clip it was cropped from.
    @Test("A portrait clip reads like its landscape twin")
    func portrait() {
        #expect(MarketplaceResolution.bucket(width: 1080, height: 1920) == "1080p")
        #expect(MarketplaceResolution.bucket(width: 2160, height: 3840) == "4K")
    }

    @Test("Nothing is claimed without dimensions")
    func missingDimensions() {
        #expect(MarketplaceResolution.bucket(width: nil, height: nil) == nil)
        #expect(MarketplaceResolution.bucket(width: 0, height: 0) == nil)
    }

    @Test("Only a footage clip earns a badge")
    func badge() {
        let dims = MarketplaceItemMetadata(width: 1920, height: 1080)
        #expect(item(.footage, metadata: .init(width: 1920, height: 1080, mediaType: "video")).resolutionBadge == "1080p")
        // A still shows its size in the detail sheet, not as a card badge.
        #expect(item(.footage, metadata: .init(width: 1920, height: 1080, mediaType: "image")).resolutionBadge == nil)
        #expect(item(.remotion, metadata: dims).resolutionBadge == nil)
        #expect(item(.audio, metadata: dims).resolutionBadge == nil)
    }

    /// Items and manifests written before media types existed carry none, and
    /// footage meant video then — so nil must keep reading as video.
    @Test("An item with no media type falls back to what its file says")
    func fallback() {
        #expect(item(.footage, filename: "frame.png").footageMediaType == .image)
        #expect(item(.footage, filename: "clip.mp4").footageMediaType == .video)
        #expect(item(.footage, filename: nil).footageMediaType == .video)
        // A stored value always wins over the filename.
        #expect(item(.footage, filename: "clip.mp4", metadata: .init(mediaType: "image")).footageMediaType == .image)
        #expect(item(.remotion, filename: "composition.zip").footageMediaType == nil)
    }

    @Test("A media type this build does not know matches nothing rather than failing")
    func unknownMediaType() {
        #expect(MarketplaceItemMetadata(mediaType: "hologram").footageMediaType == nil)
        #expect(MarketplaceItemMetadata(mediaType: "image").footageMediaType == .image)
    }

    @Test("An installed item becomes the asset kind its media type names")
    func importedAssetKind() {
        #expect(manifest(.footage, metadata: .init(mediaType: "image")).importedAssetKind == .image)
        #expect(manifest(.footage, metadata: .init(mediaType: "video")).importedAssetKind == .video)
        // Written before media types existed: footage was only ever video.
        #expect(manifest(.footage).importedAssetKind == .video)
        #expect(manifest(.audio).importedAssetKind == .audio)
        #expect(manifest(.soundEffect).importedAssetKind == .audio)
        // A composition is unpacked into a project, not imported as an asset.
        #expect(manifest(.remotion).importedAssetKind == nil)
        #expect(manifest(.font).importedAssetKind == nil)
    }
}
