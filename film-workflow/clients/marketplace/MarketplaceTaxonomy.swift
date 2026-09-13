import AppKit
import Foundation

/// The marketplace sidebar as the backend describes it: every kind with the
/// label and SF Symbol an admin picked, and every category that has something
/// published in it.
///
/// `GET api/v1/marketplace/taxonomy` returns this. The app keeps `builtIn` as
/// the shape to draw before the first load lands and whenever the call fails,
/// so the window is never empty down the side.
nonisolated struct MarketplaceTaxonomy: Codable, Hashable, Sendable {
    var kinds: [MarketplaceKindPresentation]
    var categories: [MarketplaceCategoryCount]

    init(kinds: [MarketplaceKindPresentation], categories: [MarketplaceCategoryCount] = []) {
        self.kinds = kinds
        self.categories = categories
    }

    /// A kind or a category this build does not know about is dropped rather
    /// than failing the whole payload, so the backend can add one before the
    /// app ships support for it.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try container.decodeIfPresent([Lenient<MarketplaceKindPresentation>].self, forKey: .kinds)?.compactMap { $0.value } ?? []
        categories = try container.decodeIfPresent([Lenient<MarketplaceCategoryCount>].self, forKey: .categories)?.compactMap { $0.value } ?? []
    }

    /// What the app used to hardcode, in the order the enum declares.
    static let builtIn = MarketplaceTaxonomy(
        kinds: MarketplaceKind.allCases.enumerated().map { index, kind in
            MarketplaceKindPresentation(kind: kind, label: kind.displayName, icon: kind.systemImage, sortOrder: index, count: 0)
        }
    )

    func categories(for kind: MarketplaceKind) -> [MarketplaceCategoryCount] {
        categories.filter { $0.kind == kind }
    }

    /// The backend's presentation for a kind, or the built-in one when the
    /// backend has nothing to say about it.
    func presentation(for kind: MarketplaceKind) -> MarketplaceKindPresentation {
        kinds.first { $0.kind == kind }
            ?? MarketplaceKindPresentation(kind: kind, label: kind.displayName, icon: kind.systemImage, sortOrder: 0, count: 0)
    }
}

/// One row in the top level of the sidebar.
nonisolated struct MarketplaceKindPresentation: Codable, Hashable, Identifiable, Sendable {
    let kind: MarketplaceKind
    let label: String
    /// An SF Symbol name. Resolve it through `MarketplaceSymbol` before drawing:
    /// the running macOS may not have the symbol the admin typed.
    let icon: String
    let sortOrder: Int
    let count: Int

    var id: MarketplaceKind { kind }
}

/// Decodes to `nil` instead of throwing, for elements the app may not understand.
nonisolated struct Lenient<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// Turns a backend SF Symbol name into one this Mac can actually draw.
///
/// Symbol names come from an admin form and the catalog outlives any one
/// macOS release, so an unknown name is expected rather than exceptional: it
/// falls back to the symbol the app ships with. Lookups are cached because
/// they happen once per sidebar row per render.
@MainActor
enum MarketplaceSymbol {
    private static var resolved: [String: Bool] = [:]

    static func exists(_ name: String) -> Bool {
        if let known = resolved[name] { return known }
        let known = NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        resolved[name] = known
        return known
    }

    static func resolve(_ name: String?, fallback: String) -> String {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return fallback }
        return exists(trimmed) ? trimmed : fallback
    }
}
