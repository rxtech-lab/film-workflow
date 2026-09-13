import Foundation
import Testing

@testable import film_workflow

/// The wire format is snake_case and decoded through `BackendClient`'s
/// decoder; these fixtures pin the mapping the app relies on.
@Suite("Marketplace decoding")
struct MarketplaceDecodingTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    @Test("A catalog page decodes kinds, previews, price and ownership")
    func catalogPage() throws {
        let json = """
        {"items":[{"id":"a1","kind":"remotion_prompt","category":"intros","title":"Cold open","description":"Fast cuts.",
          "price_points":120,"preview_image_url":"https://cdn.example/a.png","preview_video_url":null,
          "content_filename":"cold-open.md","content_size_bytes":812,"content_type":"text/markdown",
          "metadata":{"promptExcerpt":"Open on black…","tags":["intro","fast"]},"owned":true,"published_at":"2026-09-01T00:00:00.000Z"},
         {"id":"b2","kind":"sound_effect","category":"foley","title":"Door","description":"","price_points":0,"preview_image_url":null,
          "preview_video_url":"https://cdn.example/b.mp4","content_filename":"door.wav","content_size_bytes":null,"content_type":"audio/wav",
          "metadata":{"durationSeconds":1.5},"owned":false,"published_at":null}],
         "total":2,"page":1,"page_count":1,"page_size":24,"categories":[{"kind":"sound_effect","category":"foley","count":1}]}
        """
        let page = try decoder.decode(MarketplaceCatalogPage.self, from: Data(json.utf8))
        #expect(page.items.map(\.kind) == [.remotionPrompt, .soundEffect])
        #expect(page.items[0].pricePoints == 120)
        #expect(page.items[0].owned)
        #expect(page.items[0].isEntitled)
        #expect(page.items[0].previewImageUrl?.host == "cdn.example")
        #expect(page.items[0].metadata.tags == ["intro", "fast"])
        #expect(page.items[1].isFree)
        #expect(page.items[1].isEntitled)
        #expect(page.items[1].contentSizeBytes == nil)
        #expect(page.items[1].metadata.durationSeconds == 1.5)
        #expect(page.pageCount == 1)
        #expect(page.categories.first?.kind == .soundEffect)
    }

    @Test("Purchase and download responses decode")
    func purchaseAndDownload() throws {
        let purchase = try decoder.decode(MarketplacePurchaseResponse.self, from: Data("""
        {"purchase_id":"p1","item_id":"a1","points_charged":120,"already_owned":false,"created_at":"2026-09-01T00:00:00.000Z"}
        """.utf8))
        #expect(purchase.pointsCharged == 120)
        #expect(!purchase.alreadyOwned)
        let download = try decoder.decode(MarketplaceDownloadResponse.self, from: Data("""
        {"url":"https://r2.example/marketplace/a1/content/x.md?sig=1","filename":"cold-open.md","content_type":"text/markdown",
         "size_bytes":812,"expires_at":"2026-09-01T00:15:00.000Z","metadata":{"fontFamily":null}}
        """.utf8))
        #expect(download.filename == "cold-open.md")
        #expect(download.url.query?.contains("sig=1") == true)
        #expect(download.metadata.fontFamily == nil)
    }

    @Test("Manifests round-trip with dates")
    func manifestRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("manifest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = InstalledMarketplaceManifest(itemID: "f1", kind: .font, title: "Rx Serif", category: "serif", description: "", contentFilename: "RxSerif.ttf", contentRelativePath: "content.ttf", previewImagePath: "preview.png", metadata: .init(fontFamily: "Rx Serif"), installedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try MarketplaceStore.write(manifest, to: directory)
        let read = try #require(MarketplaceStore.read(from: directory))
        #expect(read == manifest)
        #expect(read.contentURL(in: directory).lastPathComponent == "content.ttf")
        #expect(read.previewURL(in: directory)?.lastPathComponent == "preview.png")
    }
}
