import Foundation

/// A marketplace project template the agent proposed, flattened so this
/// package never sees a marketplace type.
public nonisolated struct TemplateChoice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let reason: String
    public let previewImageURL: URL?
    public let badge: String?
    public let shotCount: Int?
    public let footageCount: Int?

    public init(
        id: String,
        title: String,
        summary: String,
        reason: String,
        previewImageURL: URL? = nil,
        badge: String? = nil,
        shotCount: Int? = nil,
        footageCount: Int? = nil
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.reason = reason
        self.previewImageURL = previewImageURL
        self.badge = badge
        self.shotCount = shotCount
        self.footageCount = footageCount
    }
}
