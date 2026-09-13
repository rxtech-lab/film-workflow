import Foundation
import VideoEffectsCore

/// Portable recipe. All identities belong to the recipe or marketplace, never a film.
nonisolated struct ProjectTemplateDefinition: Codable, Hashable, Sendable {
    struct Requirement: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var title: String = "Footage"
        var mediaType: String = "video"
        var required: Bool = true
        var instructions: String = ""
    }
    struct Dependency: Codable, Hashable, Identifiable, Sendable {
        var itemId: String
        var purpose: String
        var required: Bool = true
        var id: String { itemId }
    }
    struct Modifier: Codable, Hashable, Sendable {
        var modifierId: String
        var parameters: ModifierParameters = [:]
        var durationSeconds: Double?
    }
    struct Shot: Codable, Hashable, Identifiable, Sendable {
        var id: String = UUID().uuidString
        var title: String = "Shot"
        var instructions: String = ""
        var durationSeconds: Double = 5
        var footageRequirementId: String?
        var marketplaceItemId: String?
        var transition: Modifier?
        var effects: [Modifier] = []
    }
    var version: Int = 1
    var prompt: String = ""
    var videoStyle: String = ""
    var editingGuidance: String = ""
    var width: Int = 1920
    var height: Int = 1080
    var fps: Int = 30
    var shots: [Shot] = []
    var footageRequirements: [Requirement] = []
    var marketplaceItems: [Dependency] = []

    func validate(publishing: Bool = false) throws {
        guard version == 1 else { throw MarketplaceAuthoringError.invalid("This template needs a newer app version.") }
        guard (16...7680).contains(width), (16...7680).contains(height), (1...120).contains(fps),
              shots.count <= 100, footageRequirements.count <= 100, marketplaceItems.count <= 100,
              Set(shots.map(\.id)).count == shots.count,
              Set(footageRequirements.map(\.id)).count == footageRequirements.count,
              Set(marketplaceItems.map(\.itemId)).count == marketplaceItems.count else {
            throw MarketplaceAuthoringError.invalid("Check the template dimensions and unique shot/footage identifiers.")
        }
        for requirement in footageRequirements {
            guard ["video", "image", "audio"].contains(requirement.mediaType) else { throw MarketplaceAuthoringError.invalid("Unsupported footage type.") }
        }
        for shot in shots {
            guard shot.durationSeconds.isFinite, shot.durationSeconds > 0, shot.durationSeconds <= 600,
                  shot.footageRequirementId.map({ id in footageRequirements.contains { $0.id == id } }) ?? true,
                  shot.marketplaceItemId.map({ id in marketplaceItems.contains { $0.itemId == id } }) ?? true else {
                throw MarketplaceAuthoringError.invalid("A shot has an invalid duration or an unknown footage/item reference.")
            }
        }
        let instructions = [prompt, videoStyle, editingGuidance] + shots.flatMap { [$0.title, $0.instructions] } + footageRequirements.flatMap { [$0.title, $0.instructions] } + marketplaceItems.map(\.purpose)
        guard !instructions.contains(where: { text in ["file://", "/Users/", "/Volumes/", "/private/"].contains { text.contains($0) } }) else {
            throw MarketplaceAuthoringError.invalid("Remove local file paths from the template instructions.")
        }
        if publishing && (prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || videoStyle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || shots.isEmpty || shots.contains { $0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || footageRequirements.contains { $0.instructions.isEmpty } || shots.contains { $0.footageRequirementId == nil && $0.marketplaceItemId == nil }) {
            throw MarketplaceAuthoringError.invalid("Provide a prompt, video style, shots, and footage instructions before publishing.")
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }
    func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

nonisolated struct ProjectTemplateSummary: Codable, Hashable, Sendable {
    var videoStyle: String
    var shotCount: Int
    var footageRequirements: [ProjectTemplateDefinition.Requirement]
    var marketplaceItems: [ProjectTemplateDefinition.Dependency]
}

nonisolated enum MarketplaceAuthoringError: LocalizedError {
    case adminRequired
    case invalid(String)
    var errorDescription: String? {
        switch self {
        case .adminRequired: "An administrator account is required to create marketplace items."
        case .invalid(let reason): reason
        }
    }
}
