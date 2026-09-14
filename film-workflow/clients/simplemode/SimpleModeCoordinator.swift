import FilmTemplateKit
import Foundation
import JSONRenderUI
import Observation
import OSLog
import SwiftData
import UniformTypeIdentifiers
import VideoEditorCore

/// Runs the Simple mode wizard: owns the sessions, creates the film, and moves
/// each phase along by sending the agent its next instruction.
///
/// A singleton because the wizard's tools arrive over MCP with nothing but a
/// film to identify them, and because a session has to outlive the window it
/// started in — the user can close the Welcome window mid-run and come back.
@MainActor
@Observable
final class SimpleModeCoordinator {
    static let shared = SimpleModeCoordinator()

    /// Sessions by the id of the film they are building.
    private(set) var sessions: [UUID: SimpleModeSession] = [:]
    /// The session the wizard window should show, including before its film
    /// exists.
    private(set) var activeSession: SimpleModeSession?

    private var statusObservers: [UUID: Task<Void, Never>] = [:]

    private init() {}

    // MARK: - Lookup

    func session(forDocument id: UUID) -> SimpleModeSession? { sessions[id] }

    func session(forContainer container: ModelContainer) -> SimpleModeSession? {
        guard let document = ProjectDocumentController.shared.document(forContainer: container) else {
            return nil
        }
        return sessions[document.id]
    }

    // MARK: - Starting

    func begin(template: FilmTemplate) -> SimpleModeSession {
        // Only one run is reachable at a time — the wizard shows
        // `activeSession` — so anything still in flight would keep spending
        // tokens on a film nobody can see, cancel or finish.
        if let previous = activeSession {
            Task { await cancel(previous) }
        }
        let session = SimpleModeSession(template: template)
        activeSession = session
        return session
    }

    /// Creates the film, imports the uploads, and starts the research turn.
    func submitIntake(_ intake: IntakeSubmission, for session: SimpleModeSession) async {
        guard session.step == .chooseLocation, let destination = session.destinationURL else { return }
        session.beginCreating()
        do {
            let document = try ProjectDocumentController.shared.createDocument(at: destination)
            let uploads = await importUploads(intake.uploads, into: document)

            let context = AppModelContainer.shared.mainContext
            let thread = AgentThread(title: "\(document.displayName) — Simple mode")
            thread.documentID = document.id
            thread.documentPath = document.packageURL.path
            thread.mode = .simpleMode(templateID: session.template.id)
            // The engine the user picked on the first page. Pinned to the
            // thread rather than left to the app default so changing that
            // default mid-run cannot move the wizard onto another engine.
            thread.backendOverride = session.backend
            if session.backend != nil { AgentSettings.shared.rememberPick(from: thread) }
            context.insert(thread)
            try? context.save()

            sessions[document.id] = session
            activeSession = session
            session.beginResearch(document: document, thread: thread, intake: intake, uploads: uploads)
            observeAgent(session)

            send(
                session.template.prompts.research(
                    intake,
                    uploads.map(\.description),
                    session.template.marketplaceQueries,
                    namer(for: thread)
                ),
                in: session
            )
        } catch {
            session.locationFailed(error.localizedDescription)
        }
    }

    /// A new package in ~/Movies for callers that need an automatic name.
    /// The wizard uses the user's explicit destination instead.
    func createDocument(named name: String) throws -> ProjectDocument {
        let controller = ProjectDocumentController.shared
        // Flatten path separators before appending: `sanitized` only cleans the
        // last component, so "Acme / Q3" would otherwise name a file inside a
        // directory that does not exist.
        let trimmed = name
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled Film" : trimmed
        let directory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        for attempt in 1...50 {
            let candidate = attempt == 1 ? base : "\(base) \(attempt)"
            let url = ProjectDocumentController.sanitized(
                directory.appendingPathComponent(candidate)
            )
            guard FileManager.default.fileExists(atPath: url.path) else {
                return try controller.createDocument(at: url)
            }
        }
        throw ProjectDocumentError.alreadyExists(directory.appendingPathComponent(base))
    }

    /// Copies the user's files into the film so the agent can place them.
    /// A file that fails is skipped: losing one upload should not end the run.
    func importUploads(_ urls: [URL], into document: ProjectDocument) async -> [ImportedUpload] {
        guard !urls.isEmpty else { return [] }
        let context = document.container.mainContext
        var imported: [ImportedUpload] = []

        for url in urls {
            guard let kind = MediaImportSheet.kind(of: url) else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = try await MediaImporter.importCopy(
                    url: url,
                    kind: kind,
                    name: url.deletingPathExtension().lastPathComponent,
                    groupID: nil,
                    storage: document.storage,
                    context: context
                )
                imported.append(ImportedUpload(
                    sourceId: DocumentMediaResolver.sourceID(.imported, asset.id),
                    name: asset.name,
                    kind: kind,
                    durationSeconds: asset.durationSeconds > 0 ? asset.durationSeconds : nil
                ))
            } catch {
                logger.error("Simple mode could not import \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        try? context.save()
        return imported
    }

    // MARK: - Answers from the wizard

    func choose(template item: MarketplaceItem, for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        session.beginPlanning(with: item)
        note("The user chose the project template \"\(item.title)\" (\(item.id)).", in: session)
        send(
            session.template.prompts.planOptions(item.id, item.title, namer(for: thread)),
            in: session
        )
    }

    /// Starts planning with no template behind it, after the agent reported
    /// that the marketplace had nothing worth offering.
    func continueWithoutTemplate(for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        session.beginPlanning(with: nil)
        note("No marketplace template fitted, so the user asked you to build this film from the brief.", in: session)
        send(session.template.prompts.planOptionsWithoutTemplate(namer(for: thread)), in: session)
    }

    func confirmOptions(for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        let selections = session.optionsState.snapshotJSON
        session.beginBuilding(selections: selections)
        note("The user confirmed their choices on the options page.", in: session)
        send(buildPrompt(for: session, selections: selections, thread: thread), in: session)
    }

    /// Skips the options page after the agent failed to produce a usable one.
    func continueWithoutOptions(for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        session.beginBuilding(selections: nil)
        note(
            "The options page could not be shown, so the user asked you to go ahead with your own recommendation.",
            in: session
        )
        send(buildPrompt(for: session, selections: "{}", thread: thread), in: session)
    }

    /// Phase 3 comes in two shapes: apply the chosen template, or cut the
    /// sequence from the agent's own plan when there was never one to apply.
    private func buildPrompt(for session: SimpleModeSession, selections: String, thread: AgentThread) -> String {
        let prompts = session.template.prompts
        let tool = namer(for: thread)
        guard let item = session.chosenTemplate else {
            return prompts.buildWithoutTemplate(selections, tool)
        }
        return prompts.build(item.id, selections, tool)
    }

    /// Runs the current phase's turn again after it failed.
    ///
    /// A turn that errors leaves the wizard on a spinner with nothing to do, so
    /// every waiting phase needs a way back. Each phase's instruction is
    /// reproducible from what the session already holds.
    func retryCurrentPhase(for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        session.clearError()
        let prompts = session.template.prompts
        let tool = namer(for: thread)

        switch session.step {
        case .researching:
            guard let intake = session.intake else { return }
            send(
                prompts.research(
                    intake,
                    session.uploads.map(\.description),
                    session.template.marketplaceQueries,
                    tool
                ),
                in: session
            )
        case .planning:
            guard let item = session.chosenTemplate else {
                send(prompts.planOptionsWithoutTemplate(tool), in: session)
                return
            }
            send(prompts.planOptions(item.id, item.title, tool), in: session)
        case .building:
            send(buildPrompt(for: session, selections: session.confirmedSelections ?? "{}", thread: thread), in: session)
        default:
            return
        }
    }

    func refine(_ instruction: String, for session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        session.statusText = nil
        send(session.template.prompts.refine(instruction, namer(for: thread)), in: session)
    }

    // MARK: - Finishing

    /// Hands the film to the editor. The document stays open, so the editor
    /// window reuses it rather than reading the package a second time.
    func finish(_ session: SimpleModeSession) -> URL? {
        guard !session.isAgentRunning else { return nil }
        let url = session.document?.packageURL
        if let id = session.documentID { forget(id) }
        if activeSession === session { activeSession = nil }
        return url
    }

    /// Whether cancelling this run would put its film in the Trash.
    ///
    /// The discard prompt has to say what will actually happen, and a film with
    /// a cut in it is kept rather than thrown away.
    func cancellingDiscardsFilm(_ session: SimpleModeSession) -> Bool {
        guard let document = session.document else { return false }
        return !hasBuiltSequence(document)
    }

    /// Abandons a run. The package is only removed when nothing was built,
    /// because by then it is an empty folder the user never asked for.
    func cancel(_ session: SimpleModeSession) async {
        if let thread = session.thread {
            AgentController.shared.cancel(threadID: thread.id)
        }
        if let document = session.document {
            let isEmpty = !hasBuiltSequence(document)
            let url = document.packageURL
            forget(document.id)
            // Stop answering the agent's tools before closing the container: a
            // handler already dispatched would otherwise write to a store that
            // is going away underneath it.
            await Task.yield()
            await ProjectDocumentController.shared.close(document)
            if isEmpty {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
        }
        if activeSession === session { activeSession = nil }
    }

    private func forget(_ documentID: UUID) {
        sessions.removeValue(forKey: documentID)
        statusObservers.removeValue(forKey: documentID)?.cancel()
    }

    private func hasBuiltSequence(_ document: ProjectDocument) -> Bool {
        let context = ModelContext(document.container)
        let sequences = (try? context.fetch(FetchDescriptor<SequenceProject>())) ?? []
        return sequences.contains { !$0.timeline.allClips.isEmpty }
    }

    // MARK: - Agent plumbing

    private func send(_ instruction: String, in session: SimpleModeSession) {
        guard let thread = session.thread, let document = session.document else { return }
        // A new turn clears the last one's failure: leaving it set would pin a
        // stale message over the preview's live status for the rest of the run.
        session.clearError()
        session.noteTurnRequested()
        session.noteAgentRunning(true)
        AgentController.shared.send(
            instruction: instruction,
            thread: thread,
            context: AppModelContainer.shared.mainContext,
            container: document.container
        )
    }

    private func note(_ text: String, in session: SimpleModeSession) {
        guard let thread = session.thread else { return }
        AgentController.shared.recordDecision(
            text,
            thread: thread,
            context: AppModelContainer.shared.mainContext
        )
    }

    /// How this thread's engine will see a tool name. A CLI engine namespaces
    /// every MCP tool, so the prompt has to spell the name that engine gets.
    private func namer(for thread: AgentThread) -> @Sendable (String) -> String {
        let prefix = AgentController.shared.toolNamePrefix(for: thread)
        return { prefix + $0 }
    }

    /// Mirrors the agent's progress into the session: the tool it is running,
    /// the error it hit, and the moment a build turn finishes.
    private func observeAgent(_ session: SimpleModeSession) {
        guard let documentID = session.documentID, let thread = session.thread else { return }
        statusObservers[documentID]?.cancel()
        statusObservers[documentID] = Task { @MainActor [weak self, weak session] in
            while !Task.isCancelled, let session, self?.sessions[documentID] === session {
                let controller = AgentController.shared
                let running = controller.isRunning(thread.id)
                // An `@Observable` set notifies its observers whether or not the
                // value moved, so a poll that assigns every tick would redraw
                // the wizard twice a second.
                session.noteAgentRunning(running)

                if let label = controller.activeToolLabel(for: thread), session.statusText == nil {
                    session.statusText = label
                }
                session.noteError(controller.run(for: thread.id).errorMessage)

                // A build turn that has run and stopped, leaving clips behind,
                // means the first cut exists — whatever the agent said in prose.
                // The turn has to have started: `send` returns before the agent
                // reports busy, and the template may already have laid clips
                // down during an earlier phase.
                if case .building = session.step, session.turnHasStarted, !running,
                   let document = session.document, self?.hasBuiltSequence(document) == true {
                    session.finishBuilding(summary: controller.lastAssistantText(for: thread))
                }
                if !running, session.statusText != nil { session.statusText = nil }

                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "film-workflow", category: "simple-mode")
}
