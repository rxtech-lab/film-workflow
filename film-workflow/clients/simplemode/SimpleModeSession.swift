import FilmTemplateKit
import Foundation
import JSONRenderUI
import Observation

/// One user's trip through the Simple mode wizard.
///
/// The wizard is a state machine driven from two sides: the user moves it
/// forward by answering a page, and the agent moves it forward by calling a
/// `wizard_*` tool. Both go through here, so a tool that arrives in the wrong
/// phase is rejected with a message the agent can act on rather than quietly
/// replacing whatever the user is currently looking at.
@MainActor
@Observable
final class SimpleModeSession: Identifiable {
    enum Step: Equatable {
        /// Picking the engine that will build the film.
        case chooseEngine
        /// Filling in the brief. Nothing exists yet.
        case intake
        /// Choosing the package's name and location before any work starts.
        case chooseLocation
        /// Creating the package and importing the uploads.
        case creating
        /// The agent is reading the website and searching the marketplace.
        case researching
        case chooseTemplate([TemplateChoice])
        /// The agent is working out what to ask about.
        case planning
        case chooseOptions(JSONRenderSpec, String)
        /// The agent could not produce a page it can draw; go with its picks.
        case optionsUnavailable(String)
        case building
        case preview
        case failed(String)

        var wizardStep: WizardStep {
            switch self {
            case .chooseEngine: .engine
            case .intake: .intake
            case .chooseLocation, .creating: .location
            case .researching: .research
            case .chooseTemplate: .chooseTemplate
            case .planning, .chooseOptions, .optionsUnavailable: .chooseOptions
            case .building: .build
            case .preview, .failed: .preview
            }
        }
    }

    let id = UUID()
    let template: FilmTemplate

    private(set) var step: Step = .chooseEngine

    /// The engine this run's thread is pinned to, or nil to follow the app
    /// default. Picked on the first page, before anything else exists.
    private(set) var backend: AgentBackend?

    var document: ProjectDocument?
    var thread: AgentThread?
    private(set) var intake: IntakeSubmission?
    private(set) var destinationURL: URL?
    private(set) var uploads: [ImportedUpload] = []
    private(set) var chosenTemplate: MarketplaceItem?
    /// The full items behind the presented choices, so picking one hands the
    /// coordinator a real item rather than an id it would have to fetch again.
    private var candidates: [String: MarketplaceItem] = [:]

    /// Values behind the current options page. Held across a re-present so a
    /// second attempt by the agent does not lose what the user already picked.
    private(set) var optionsState = JSONRenderState()
    private(set) var optionsTitle = "Choose how it looks"
    private(set) var confirmedSelections: String?

    /// The line under the spinner: whatever the agent last reported, or the
    /// tool it is running.
    var statusText: String?
    var isAgentRunning = false
    var lastSummary: String?
    var error: String?

    /// Whether the turn for the current phase has actually started.
    ///
    /// `AgentController.send` hops through a Task before the agent reports
    /// busy, so for a moment after asking for a build nothing is running. A
    /// poll landing there would call the build finished before it began — and
    /// the template may already have left clips behind, so "are there clips?"
    /// cannot tell the difference on its own.
    private(set) var turnHasStarted = false

    /// Two rejected specs in a row and the wizard stops asking; the agent's own
    /// recommendation is better than a page the user cannot use.
    private(set) var rejectedOptionPresents = 0
    static let maxOptionAttempts = 2

    init(template: FilmTemplate) {
        self.template = template
    }

    var documentID: UUID? { document?.id }

    var canRefine: Bool {
        if case .preview = step { return true }
        if case .building = step { return true }
        return false
    }

    // MARK: - Transitions driven by the app

    /// Records the engine and moves on to the brief.
    func chooseEngine(_ backend: AgentBackend?) {
        self.backend = backend
        error = nil
        step = .intake
    }

    /// Back to the engine page, for a run that has not created anything yet.
    func returnToEngine() {
        error = nil
        step = .chooseEngine
    }

    func beginCreating() { step = .creating }

    func reviewLocation(for intake: IntakeSubmission) {
        self.intake = intake
        error = nil
        step = .chooseLocation
    }

    func chooseDestination(_ url: URL) {
        destinationURL = ProjectDocumentController.sanitized(url)
        error = nil
    }

    func returnToBrief() {
        error = nil
        step = .intake
    }

    func locationFailed(_ message: String) {
        error = message
        step = .chooseLocation
    }

    #if DEBUG
        /// Drops the session into a phase without the work that normally gets
        /// it there, so the transition rules can be tested on their own.
        func step_forTesting(_ step: Step) { self.step = step }
    #endif


    func beginResearch(document: ProjectDocument, thread: AgentThread, intake: IntakeSubmission, uploads: [ImportedUpload]) {
        self.document = document
        self.thread = thread
        self.intake = intake
        self.uploads = uploads
        error = nil
        step = .researching
    }

    func rememberCandidate(_ item: MarketplaceItem) {
        candidates[item.id] = item
    }

    func candidate(id: String) -> MarketplaceItem? { candidates[id] }

    func beginPlanning(with item: MarketplaceItem) {
        chosenTemplate = item
        statusText = nil
        step = .planning
    }

    func beginBuilding(selections: String?) {
        confirmedSelections = selections
        statusText = nil
        turnHasStarted = false
        step = .building
    }

    /// Records that the agent is running, which is what makes the end of a turn
    /// meaningful.
    func noteAgentRunning(_ running: Bool) {
        if running { turnHasStarted = true }
        if isAgentRunning != running { isAgentRunning = running }
    }

    /// Called when a phase is asked for again, so the next stop counts as the
    /// end of the new turn rather than the old one.
    func noteTurnRequested() {
        turnHasStarted = false
    }

    func finishBuilding(summary: String?) {
        lastSummary = summary ?? lastSummary
        statusText = nil
        step = .preview
    }

    func clearError() {
        error = nil
        statusText = nil
    }

    func noteError(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        if error != message { error = message }
    }

    func fail(_ message: String) {
        error = message
        step = .failed(message)
    }

    /// Back to the brief after a failure the user wants to retry.
    func restartIntake() {
        error = nil
        statusText = nil
        step = .intake
    }

    // MARK: - Transitions driven by the agent
    //
    // Each returns the sentence the tool result carries back, or throws when
    // the call does not belong in the current phase.

    @discardableResult
    func present(templates: [TemplateChoice], summary: String?) throws -> String {
        switch step {
        case .researching, .chooseTemplate:
            guard !templates.isEmpty else {
                throw SimpleModeError.rejected("No usable templates were listed. Search again and include at least one item_id that marketplace_list returned.")
            }
            if let summary, !summary.isEmpty { lastSummary = summary }
            statusText = nil
            step = .chooseTemplate(templates)
            return "Presented \(templates.count) template\(templates.count == 1 ? "" : "s") to the user. Stop now; their choice arrives as your next message."
        default:
            throw SimpleModeError.rejected("Templates cannot be presented during \(phaseName). \(nextExpectedHint)")
        }
    }

    @discardableResult
    func present(spec: JSONRenderSpec, title: String?, initialState: JSONRenderValue?) throws -> String {
        switch step {
        case .planning, .chooseOptions, .optionsUnavailable:
            if let title, !title.isEmpty { optionsTitle = title }
            // Seed once. A re-present after the user has been picking should
            // not throw their answers away.
            if let initialState, optionsState.snapshot.object?.isEmpty != false {
                optionsState = JSONRenderState(initialState)
            }
            statusText = nil
            rejectedOptionPresents = 0
            step = .chooseOptions(spec, optionsTitle)
            var message = "Presented the options page. Stop now; the user's choices arrive as your next message."
            let dangling = spec.danglingChildren
            if !dangling.isEmpty {
                message += " Note: these child ids name no element and were skipped — \(dangling.joined(separator: ", "))."
            }
            return message
        default:
            throw SimpleModeError.rejected("Options cannot be presented during \(phaseName). \(nextExpectedHint)")
        }
    }

    /// Counts a spec the renderer refused. After the second, the wizard offers
    /// to continue on the agent's recommendation instead.
    ///
    /// Only while the wizard is actually asking. A bad spec sent during, say,
    /// template selection must not replace the page the user is reading with a
    /// fallback that has no template to build from.
    func recordRejectedOptions(_ reason: String) -> Bool {
        switch step {
        case .planning, .chooseOptions, .optionsUnavailable:
            break
        default:
            return false
        }
        rejectedOptionPresents += 1
        guard rejectedOptionPresents >= Self.maxOptionAttempts else { return false }
        step = .optionsUnavailable(reason)
        return true
    }

    @discardableResult
    func report(progress message: String) throws -> String {
        switch step {
        case .chooseEngine, .intake, .chooseLocation:
            throw SimpleModeError.rejected("The wizard has not started yet.")
        default:
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            statusText = trimmed.isEmpty ? nil : trimmed
            return "ok"
        }
    }

    // MARK: - Options

    func replaceOptionsState(_ state: JSONRenderState) { optionsState = state }

    private var phaseName: String {
        switch step {
        case .chooseEngine: "engine selection"
        case .intake: "the brief"
        case .chooseLocation: "save location"
        case .creating: "setup"
        case .researching: "research"
        case .chooseTemplate: "template selection"
        case .planning: "planning"
        case .chooseOptions, .optionsUnavailable: "the options page"
        case .building: "the build"
        case .preview: "the preview"
        case .failed: "an error"
        }
    }

    private var nextExpectedHint: String {
        switch step {
        case .building, .preview:
            "Finish the edit with the sequence tools and reply with one sentence."
        case .chooseTemplate:
            "The user is choosing a template; wait for their answer."
        case .chooseOptions:
            "The user is answering your options page; wait for their answer."
        default:
            "Wait for the wizard to reach the right phase."
        }
    }
}

/// One imported upload, in the shape both the prompts and the option cards use.
nonisolated struct ImportedUpload: Hashable, Sendable {
    let sourceId: String
    let name: String
    let kind: ImportedAssetKind
    let durationSeconds: Double?

    var description: WizardUploadDescription {
        WizardUploadDescription(
            sourceId: sourceId,
            name: name,
            kind: kind.rawValue,
            durationSeconds: durationSeconds
        )
    }
}

enum SimpleModeError: LocalizedError {
    case rejected(String)
    case noSession
    case noDocument

    var errorDescription: String? {
        switch self {
        case .rejected(let message): message
        case .noSession: "This film is not being built by the Simple mode wizard, so wizard tools do not apply here."
        case .noDocument: "The film is not open."
        }
    }
}
