import Foundation

/// The tools that exist only inside a Simple mode run.
///
/// The agent cannot ask the user a question in prose here: the wizard shows
/// pages, not a transcript. These tools are how a turn hands a page to the
/// wizard and stops, and how the wizard's answer comes back as the next turn.
public enum WizardTool {
    public static let presentTemplates = "wizard_present_templates"
    public static let presentOptions = "wizard_present_options"
    public static let reportProgress = "wizard_report_progress"

    public static let all: [String] = [presentTemplates, presentOptions, reportProgress]

    public static func isWizardTool(_ name: String) -> Bool { all.contains(name) }
}

/// Reading the open web. The coding agents' own `WebFetch` is withheld from
/// every thread and only exists on the CLI engines, so Simple mode brings its
/// own tool that all five engines can call.
public enum WebTool {
    public static let read = "web_read"
}

/// One marketplace project template the agent is proposing.
public struct WizardTemplateCandidate: Codable, Hashable, Sendable, Identifiable {
    public var itemId: String
    public var reason: String
    public var fitScore: Double?

    public var id: String { itemId }

    public init(itemId: String, reason: String, fitScore: Double? = nil) {
        self.itemId = itemId
        self.reason = reason
        self.fitScore = fitScore
    }

    private enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case reason
        case fitScore = "fit_score"
    }
}

/// The arguments of `wizard_present_templates`, as the Agent window's card
/// reads them back off a persisted tool row.
public struct WizardTemplatesPayload: Codable, Hashable, Sendable {
    public var candidates: [WizardTemplateCandidate]
    public var summary: String?

    public init(candidates: [WizardTemplateCandidate], summary: String? = nil) {
        self.candidates = candidates
        self.summary = summary
    }
}

/// The arguments of `wizard_present_options`: a json-render spec plus the
/// values it should start with.
public struct WizardOptionsPayload: Hashable, Sendable {
    public var title: String?
    public var specJSON: String
    public var initialStateJSON: String?

    public init(title: String? = nil, specJSON: String, initialStateJSON: String? = nil) {
        self.title = title
        self.specJSON = specJSON
        self.initialStateJSON = initialStateJSON
    }
}
