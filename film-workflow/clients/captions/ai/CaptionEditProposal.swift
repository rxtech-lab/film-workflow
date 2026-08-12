import Foundation

/// A single change an AI backend wants to make to a caption project.
///
/// Deliberately a small, closed vocabulary. The model never writes text into
/// SwiftData; it describes an operation, the operation is validated against the
/// current transcript, and only then can the user apply it.
nonisolated enum CaptionEditOperation: Codable, Sendable, Hashable {
    /// Replace one caption with several, in order. Pieces reconstruct the
    /// original words; punctuation may differ.
    case split(segment: UUID, pieces: [String])
    /// Rewrite one caption's text. Used by the glossary pass.
    case replaceText(segment: UUID, newText: String)
    /// Absorb the following caption into this one.
    case merge(segment: UUID, withNext: UUID)
    case setSpeaker(segment: UUID, speaker: UUID)
    case delete(segment: UUID)

    var segmentID: UUID {
        switch self {
        case .split(let id, _), .replaceText(let id, _), .merge(let id, _),
             .setSpeaker(let id, _), .delete(let id):
            return id
        }
    }
}

/// Why an operation can't be trusted. Present on an item means it arrives in
/// the review sheet unchecked, with the reason shown.
nonisolated enum CaptionEditVerdict: Codable, Sendable, Hashable {
    case ok
    /// The pieces don't reconstruct the original words.
    case wordsChanged
    /// A resulting piece is too short to be a readable line.
    case stubPiece
    /// The caption was broken into far more lines than its length required.
    case overSplit
    /// A text edit touched something that isn't a glossary term.
    case editedNonTerm(String)
    /// The operation refers to a caption that no longer exists, or is otherwise
    /// unapplicable.
    case notApplicable(String)

    var isOK: Bool { self == .ok }

    /// User-facing explanation. `LocalizedStringKey` so the review sheet
    /// localizes it; see the `CaptionProgress.title` precedent.
    var message: String {
        switch self {
        case .ok:
            return ""
        case .wordsChanged:
            return "The suggested text changes the spoken words, not just the line breaks."
        case .stubPiece:
            return "This would leave a very short second line."
        case .overSplit:
            return "This breaks the caption into more lines than its length calls for."
        case .editedNonTerm(let word):
            return "This changes \"\(word)\", which isn't in the glossary."
        case .notApplicable(let reason):
            return reason
        }
    }
}

/// One reviewable row: the operation, what it looks like before and after, and
/// whether it passed validation.
nonisolated struct CaptionEditProposalItem: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var operation: CaptionEditOperation
    /// 1-based caption number as shown in the editor, for the row header.
    var displayIndex: Int
    var startMs: Int
    var before: String
    /// Rendered result — joined with " / " for a split, so one row reads as one
    /// change rather than N.
    var after: String
    var verdict: CaptionEditVerdict = .ok
    /// Explanation from the model, when it gave one.
    var reason: String = ""

    var isApplicableByDefault: Bool { verdict.isOK }
}

nonisolated struct CaptionEditProposal: Codable, Sendable, Hashable, Identifiable {
    var id: UUID = UUID()
    var summary: String = ""
    /// Which engine produced this — "Apple Intelligence", a model id like
    /// "gpt-4o", or a CLI's name. Two engines give noticeably different
    /// suggestions, so the user can't judge a batch without knowing whose it is.
    var engine: String = ""
    var items: [CaptionEditProposalItem] = []

    var isEmpty: Bool { items.isEmpty }
    var okCount: Int { items.count(where: \.verdict.isOK) }

    init(
        id: UUID = UUID(),
        summary: String = "",
        engine: String = "",
        items: [CaptionEditProposalItem] = []
    ) {
        self.id = id
        self.summary = summary
        self.engine = engine
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, summary, engine, items
    }

    /// Decoded key by key rather than by the synthesized initializer, which
    /// treats every key as required: a proposal persisted on an assistant
    /// message before `engine` existed must still re-open.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        engine = try container.decodeIfPresent(String.self, forKey: .engine) ?? ""
        items = try container.decodeIfPresent([CaptionEditProposalItem].self, forKey: .items) ?? []
    }

    // MARK: - JSON round-trip
    //
    // Proposals are persisted on an assistant message so a turn can be reviewed
    // again later, and are parsed out of an MCP tool call.

    func encodedJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decode(fromJSON json: String) -> CaptionEditProposal? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CaptionEditProposal.self, from: data)
    }
}
