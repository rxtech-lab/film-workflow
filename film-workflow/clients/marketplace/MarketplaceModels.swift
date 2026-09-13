import Foundation

/// Mirrors `marketplace_kind` on the server; raw values are the wire strings.
nonisolated enum MarketplaceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case footage
    case remotionPrompt = "remotion_prompt"
    case audio
    case soundEffect = "sound_effect"
    case font
    case transition
    case effect
    case projectTemplate = "project_template"

    var id: String { rawValue }

    /// What the sidebar shows when the backend has no label for this kind —
    /// see `MarketplaceTaxonomy`, which is where the app reads them from now.
    var displayName: String {
        switch self {
        case .footage: return String(localized: "Footage")
        case .remotionPrompt: return String(localized: "Remotion Prompts")
        case .audio: return String(localized: "Music")
        case .soundEffect: return String(localized: "Sound Effects")
        case .font: return String(localized: "Fonts")
        case .transition: return String(localized: "Transitions")
        case .effect: return String(localized: "Effects")
        case .projectTemplate: return String(localized: "Project Templates")
        }
    }

    /// The fallback SF Symbol, used when the backend has none or names one
    /// this macOS cannot draw.
    var systemImage: String {
        switch self {
        case .footage: return "film"
        case .remotionPrompt: return "text.quote"
        case .audio: return "music.note"
        case .soundEffect: return "waveform"
        case .font: return "textformat"
        case .transition: return "arrow.left.arrow.right.square"
        case .effect: return "wand.and.stars"
        case .projectTemplate: return "rectangle.stack.badge.play"
        }
    }

    /// The footage kind an installed file becomes when added to a film, if any.
    var importedAssetKind: ImportedAssetKind? {
        switch self {
        case .footage: return .video
        case .audio, .soundEffect: return .audio
        case .remotionPrompt, .font, .transition, .effect, .projectTemplate: return nil
        }
    }

    /// Fonts, effects and transitions are global once installed; the rest are added per film.
    var addsToFilm: Bool {
        switch self {
        case .footage, .audio, .soundEffect, .remotionPrompt: return true
        case .font, .transition, .effect, .projectTemplate: return false
        }
    }

    /// Where an installed item shows up, for the button that stands in for "Add to Film".
    var installedHint: String {
        switch self {
        case .font: return String(localized: "Available in the caption Text Style font picker.")
        case .transition, .effect: return String(localized: "Available in the Effects & Transitions browser.")
        default: return ""
        }
    }
}

nonisolated struct MarketplaceItemMetadata: Codable, Hashable, Sendable {
    struct Descriptor: Codable, Hashable, Sendable {
        var filterName: String
        var parameterCount: Int
    }
    var durationSeconds: Double?
    var width: Int?
    var height: Int?
    var fontFamily: String?
    var descriptor: Descriptor?
    var promptExcerpt: String?
    var tags: [String]?
    var preview: Preview?
    var template: ProjectTemplateSummary?
    struct Preview: Codable, Hashable, Sendable {
        var durationSeconds: Double?
        var width: Int?
        var height: Int?
        var mock: Bool?
    }

    init(durationSeconds: Double? = nil, width: Int? = nil, height: Int? = nil, fontFamily: String? = nil,
         descriptor: Descriptor? = nil, promptExcerpt: String? = nil, tags: [String]? = nil) {
        self.durationSeconds = durationSeconds; self.width = width; self.height = height; self.fontFamily = fontFamily
        self.descriptor = descriptor; self.promptExcerpt = promptExcerpt; self.tags = tags
    }
}

/// One catalog entry as `GET api/v1/marketplace/items` returns it. Decoded
/// through `BackendClient`, whose decoder maps snake_case keys.
nonisolated struct MarketplaceItem: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let kind: MarketplaceKind
    /// The category slug.
    let category: String
    /// What the category is called; nil from a server that predates the field.
    let categoryName: String?
    let title: String
    let description: String
    let pricePoints: Int
    let previewImageUrl: URL?
    let previewVideoUrl: URL?
    let contentFilename: String?
    let contentSizeBytes: Int64?
    let contentType: String?
    let metadata: MarketplaceItemMetadata
    var owned: Bool
    let publishedAt: String?

    var isFree: Bool { pricePoints <= 0 }
    /// Free items never need a purchase row; paid ones need `owned`.
    var isEntitled: Bool { isFree || owned }

    /// The category as the card should print it.
    var categoryLabel: String { categoryName ?? category }

    init(id: String, kind: MarketplaceKind, category: String, categoryName: String? = nil, title: String, description: String = "", pricePoints: Int = 0,
         previewImageUrl: URL? = nil, previewVideoUrl: URL? = nil, contentFilename: String? = nil, contentSizeBytes: Int64? = nil,
         contentType: String? = nil, metadata: MarketplaceItemMetadata = .init(), owned: Bool = false, publishedAt: String? = nil) {
        self.id = id; self.kind = kind; self.category = category; self.categoryName = categoryName; self.title = title; self.description = description
        self.pricePoints = pricePoints; self.previewImageUrl = previewImageUrl; self.previewVideoUrl = previewVideoUrl
        self.contentFilename = contentFilename; self.contentSizeBytes = contentSizeBytes; self.contentType = contentType
        self.metadata = metadata; self.owned = owned; self.publishedAt = publishedAt
    }
}

/// One category shelf: the slug the catalog filters on plus how the sidebar
/// should draw it. `name` and `icon` come from the backend; both are optional
/// so a server that predates them still decodes.
nonisolated struct MarketplaceCategoryCount: Codable, Hashable, Identifiable, Sendable {
    let kind: MarketplaceKind
    /// The slug, e.g. `lo-fi-beats`.
    let category: String
    var name: String?
    /// An SF Symbol name; resolve it through `MarketplaceSymbol` before drawing.
    var icon: String?
    let count: Int

    var id: String { "\(kind.rawValue)/\(category)" }
    /// The backend's name, falling back to the slug an older server sends.
    var displayName: String { name ?? category }
}

nonisolated struct MarketplaceCatalogPage: Codable, Sendable {
    var items: [MarketplaceItem]
    var total: Int
    var page: Int
    var pageCount: Int
    var pageSize: Int
    var categories: [MarketplaceCategoryCount]
}

nonisolated struct MarketplacePurchaseResponse: Codable, Sendable {
    let purchaseId: String
    let itemId: String
    let pointsCharged: Int
    let alreadyOwned: Bool
}

nonisolated struct MarketplaceDownloadResponse: Codable, Sendable {
    let url: URL
    let filename: String
    let contentType: String
    let sizeBytes: Int64?
    let expiresAt: String
    let metadata: MarketplaceItemMetadata
}

nonisolated struct MarketplacePurchaseRecord: Codable, Identifiable, Sendable {
    let id: String
    let item: MarketplaceItem
    let pointsCharged: Int
    let createdAt: String
}

nonisolated struct MarketplacePurchasesResponse: Codable, Sendable {
    let purchases: [MarketplacePurchaseRecord]
}

/// `manifest.json` beside an installed item's content. Written and read with
/// a plain encoder: keys are camelCase on disk.
nonisolated struct InstalledMarketplaceManifest: Codable, Hashable, Identifiable, Sendable {
    var version: Int = 1
    var itemID: String
    var kind: MarketplaceKind
    var title: String
    var category: String
    var description: String
    var contentFilename: String
    /// Relative to the item directory, e.g. `content.ttf`.
    var contentRelativePath: String
    var previewImagePath: String?
    var metadata: MarketplaceItemMetadata
    var installedAt: Date

    var id: String { itemID }

    static let filename = "manifest.json"

    func contentURL(in directory: URL) -> URL { directory.appendingPathComponent(contentRelativePath) }
    func previewURL(in directory: URL) -> URL? { previewImagePath.map { directory.appendingPathComponent($0) } }
}

nonisolated enum MarketplaceError: LocalizedError, Equatable {
    case notSignedIn
    case notEntitled
    case downloadFailed(Int)
    case noActiveFilm
    case notAddable(MarketplaceKind)
    case invalidDescriptor(String)
    case fontRegistrationFailed(String)
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return String(localized: "Sign in to use the marketplace.")
        case .notEntitled: return String(localized: "Buy this item before installing it.")
        case .downloadFailed(let status): return status == 0 ? String(localized: "The download did not complete.") : String(localized: "The download failed (HTTP \(status)).")
        case .noActiveFilm: return String(localized: "Open a film first.")
        case .notAddable(let kind): return String(localized: "\(kind.displayName) are installed globally and do not need adding to a film.")
        case .invalidDescriptor(let reason): return String(localized: "This effect cannot be loaded: \(reason)")
        case .fontRegistrationFailed(let name): return String(localized: "The font \(name) could not be registered.")
        case .notInstalled: return String(localized: "Install this item first.")
        }
    }
}

extension MarketplaceError {
    /// True when a failure is only a cancelled task or request — the user typed
    /// another character, changed the filter, or closed the window. Nothing went
    /// wrong, so these must never reach `lastError`.
    nonisolated static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError { return urlError.code == .cancelled }
        let error = error as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
