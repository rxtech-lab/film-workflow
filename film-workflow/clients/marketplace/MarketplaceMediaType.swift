import Foundation

/// The sub-dimension footage carries: a still or a clip.
///
/// The server derives it from the content file at finalize and sends it as
/// `metadata.media_type`, so the shelf an item sits on always matches the bytes
/// behind it. Kinds other than footage have none.
nonisolated enum MarketplaceMediaType: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case image
    case video

    var id: String { rawValue }

    /// What the sidebar shows when the backend has no label for it.
    var displayName: String {
        switch self {
        case .image: return String(localized: "Images")
        case .video: return String(localized: "Video")
        }
    }

    /// The fallback SF Symbol, resolved through `MarketplaceSymbol` before drawing.
    var systemImage: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        }
    }
}

/// The resolution bucket a catalog card prints.
///
/// Measured on the short side, so a portrait clip reads the same as its
/// landscape equivalent: 1080×1920 is 1080p, not 1440p. The detail sheet keeps
/// the exact dimensions; this is only the badge that has to survive a grid.
///
/// Mirrors `resolutionLabel()` in `website/lib/marketplace/schema.ts`. Change both.
nonisolated enum MarketplaceResolution {
    static func bucket(width: Int?, height: Int?) -> String? {
        let w = width ?? 0, h = height ?? 0
        let short = w > 0 && h > 0 ? min(w, h) : h
        switch short {
        case 2160...: return "4K"
        case 1440..<2160: return "1440p"
        case 1080..<1440: return "1080p"
        case 720..<1080: return "720p"
        case 1..<720: return String(localized: "SD")
        default: return nil
        }
    }

    static func bucket(_ metadata: MarketplaceItemMetadata) -> String? {
        bucket(width: metadata.width, height: metadata.height)
    }
}

extension MarketplaceItem {
    /// Which footage shelf this item belongs on.
    ///
    /// Falls back to the content filename so a draft uploaded before the server
    /// started recording media types still renders and installs correctly. Nil
    /// for every kind that has no media type at all.
    var footageMediaType: MarketplaceMediaType? {
        guard kind == .footage else { return nil }
        if let stored = metadata.footageMediaType { return stored }
        let ext = (contentFilename as NSString?)?.pathExtension.lowercased() ?? ""
        if ["png", "jpg", "jpeg", "webp"].contains(ext) { return .image }
        if ["mp4", "mov"].contains(ext) { return .video }
        // Footage was only ever video before media types existed.
        return .video
    }

    /// The bucket the catalog card prints, for clips that have dimensions.
    var resolutionBadge: String? {
        guard kind == .footage, footageMediaType == .video else { return nil }
        return MarketplaceResolution.bucket(metadata)
    }
}
