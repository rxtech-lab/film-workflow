import Foundation
import Testing

@testable import film_workflow

/// Canned responses in place of the network. The download URL points at a
/// local file, which `URLSession` downloads like anything else.
final class FakeMarketplaceTransport: MarketplaceTransport, @unchecked Sendable {
    var page: MarketplaceCatalogPage
    var downloadFile: URL
    var purchaseError: Error?
    var purchaseCalls = 0
    var downloadCalls = 0

    init(page: MarketplaceCatalogPage, downloadFile: URL) {
        self.page = page
        self.downloadFile = downloadFile
    }

    func get<Response: Decodable>(_ path: String, query: [URLQueryItem]) async throws -> Response {
        if path == "api/v1/marketplace/items" { return page as! Response }
        if path.hasSuffix("/download") {
            downloadCalls += 1
            let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let item = page.items.first { $0.id == id }
            return MarketplaceDownloadResponse(url: downloadFile, filename: item?.contentFilename ?? "content.txt", contentType: "text/plain", sizeBytes: nil, expiresAt: "", metadata: item?.metadata ?? .init()) as! Response
        }
        throw BackendError.server(404, "unknown path \(path)")
    }

    func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, idempotencyKey: String?) async throws -> Response {
        purchaseCalls += 1
        if let purchaseError { throw purchaseError }
        let id = path.split(separator: "/").dropLast().last.map(String.init) ?? ""
        return MarketplacePurchaseResponse(purchaseId: "p-\(id)", itemId: id, pointsCharged: 10, alreadyOwned: false) as! Response
    }
}

@Suite("Marketplace store", .serialized)
@MainActor
struct MarketplaceStoreTests {
    private func fixture() throws -> (store: MarketplaceStore, transport: FakeMarketplaceTransport, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("marketplace-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.txt")
        try Data("hello".utf8).write(to: source)
        let items = [
            MarketplaceItem(id: "free", kind: .remotionPrompt, category: "intros", title: "Free prompt", contentFilename: "prompt.md"),
            MarketplaceItem(id: "paid", kind: .soundEffect, category: "foley", title: "Door", pricePoints: 10, contentFilename: "door.wav"),
        ]
        let page = MarketplaceCatalogPage(items: items, total: 2, page: 1, pageCount: 1, pageSize: 24, categories: [MarketplaceCategoryCount(kind: .soundEffect, category: "foley", count: 1)])
        let transport = FakeMarketplaceTransport(page: page, downloadFile: source)
        let store = MarketplaceStore(client: MarketplaceClient(transport: transport), root: root)
        store.balanceRefresher = {}
        return (store, transport, root)
    }

    @Test("Loading fills items and categories")
    func load() async throws {
        let (store, _, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.load(kind: nil, category: nil, query: "")
        #expect(store.items.map(\.id) == ["free", "paid"])
        #expect(store.categories.count == 1)
        #expect(store.lastError == nil)
        #expect(store.installed.isEmpty)
    }

    @Test("A paid item cannot be installed until it is bought, then installs to disk")
    func purchaseThenInstall() async throws {
        let (store, transport, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.load(kind: nil, category: nil, query: "")
        let paid = try #require(store.item("paid"))
        #expect(await store.install(paid) == false)
        #expect(store.lastError == MarketplaceError.notEntitled.errorDescription)
        #expect(transport.downloadCalls == 0)

        #expect(await store.purchase(paid))
        #expect(transport.purchaseCalls == 1)
        #expect(store.item("paid")?.owned == true)

        let owned = try #require(store.item("paid"))
        #expect(await store.install(owned))
        #expect(transport.downloadCalls == 1)
        let manifest = try #require(store.manifest(for: "paid"))
        #expect(manifest.kind == .soundEffect)
        #expect(manifest.contentRelativePath == "content.wav")
        let content = manifest.contentURL(in: store.directory(for: manifest))
        #expect(try String(contentsOf: content, encoding: .utf8) == "hello")
        #expect(store.downloadProgress["paid"] == nil)
        #expect(store.busyItemIDs.isEmpty)

        // Ownership survives a reload, and the installed state survives a fresh store.
        await store.load(kind: nil, category: nil, query: "")
        #expect(store.item("paid")?.owned == true)
        let again = MarketplaceStore(client: MarketplaceClient(transport: transport), root: root)
        #expect(again.isInstalled("paid"))

        store.uninstall("paid")
        #expect(!store.isInstalled("paid"))
        #expect(!FileManager.default.fileExists(atPath: content.path))
    }

    @Test("Insufficient credits becomes the alert, not an error line")
    func insufficientCredits() async throws {
        let (store, transport, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        transport.purchaseError = BackendError.insufficientCredits(available: 3, required: 10, creditsURL: nil)
        await store.load(kind: nil, category: nil, query: "")
        let paid = try #require(store.item("paid"))
        #expect(await store.purchase(paid) == false)
        #expect(store.insufficientCredits?.required == 10)
        #expect(store.insufficientCredits?.available == 3)
        #expect(store.lastError == nil)
        #expect(store.item("paid")?.owned == false)
    }

    @Test("A free item installs without a purchase and a failed download leaves nothing behind")
    func freeInstallAndFailure() async throws {
        let (store, transport, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        await store.load(kind: nil, category: nil, query: "")
        let free = try #require(store.item("free"))
        #expect(await store.install(free))
        #expect(transport.purchaseCalls == 0)
        #expect(store.manifest(for: "free")?.contentRelativePath == "content.md")

        transport.downloadFile = root.appendingPathComponent("missing.txt")
        store.uninstall("free")
        #expect(await store.install(free) == false)
        #expect(store.lastError != nil)
        #expect(!store.isInstalled("free"))
        #expect(!FileManager.default.fileExists(atPath: FileStorage.marketplaceItemDir(kind: "remotion_prompt", itemID: "free", root: root).path))
    }
}
