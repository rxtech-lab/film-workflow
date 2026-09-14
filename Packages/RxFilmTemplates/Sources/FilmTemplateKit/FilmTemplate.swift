import Foundation

/// A guided path from "New Film" to a first cut.
///
/// A template is a script for the wizard, not a video: it says which questions
/// to ask, which marketplace project templates to look for, and what to tell
/// the agent at each step. The footage, the shots and the styling all come from
/// a marketplace project template the agent picks during the run.
public struct FilmTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let group: FilmTemplateGroup
    public let title: String
    public let summary: String
    /// SF Symbol for the gallery card.
    public let systemImage: String
    /// What to search the marketplace for, in ranked order.
    public let marketplaceQueries: [String]
    public let intake: IntakeFormDefinition
    public let prompts: WizardPromptSet

    public init(
        id: String,
        group: FilmTemplateGroup,
        title: String,
        summary: String,
        systemImage: String,
        marketplaceQueries: [String],
        intake: IntakeFormDefinition,
        prompts: WizardPromptSet
    ) {
        self.id = id
        self.group = group
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.marketplaceQueries = marketplaceQueries
        self.intake = intake
        self.prompts = prompts
    }

    /// The steps every guided template walks through, in order.
    public var steps: [WizardStep] { WizardStep.allCases }
}

/// The gallery's sections. New groups are added here as templates arrive.
public enum FilmTemplateGroup: String, CaseIterable, Hashable, Sendable {
    case marketing
    case social
    case product

    public var title: String {
        switch self {
        case .marketing: "Marketing"
        case .social: "Social"
        case .product: "Product"
        }
    }

    public var summary: String {
        switch self {
        case .marketing: "Introduce a company or a campaign."
        case .social: "Short films built for a feed."
        case .product: "Show a product in use."
        }
    }
}

/// The wizard's phases. The progress header shows these; the session's state
/// machine moves through them.
public enum WizardStep: String, CaseIterable, Hashable, Sendable, Identifiable {
    /// Which AI engine builds the film. First because everything after it runs
    /// on the agent: an engine that is not signed in, not installed or out of
    /// credits fails on the research turn, long after the user has typed a
    /// brief.
    case engine
    case intake
    case location
    case research
    case chooseTemplate
    case chooseOptions
    case build
    case preview

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .engine: "Engine"
        case .intake: "Your brief"
        case .location: "Save location"
        case .research: "Research"
        case .chooseTemplate: "Template"
        case .chooseOptions: "Style"
        case .build: "Build"
        case .preview: "Preview"
        }
    }

    public var shortTitle: String {
        switch self {
        case .engine: "Engine"
        case .intake: "Brief"
        case .location: "Location"
        case .research: "Research"
        case .chooseTemplate: "Template"
        case .chooseOptions: "Style"
        case .build: "Build"
        case .preview: "Preview"
        }
    }
}
