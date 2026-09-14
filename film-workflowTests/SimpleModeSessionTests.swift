import FilmTemplateKit
import Foundation
import JSONRenderUI
import Testing

@testable import film_workflow

@Suite("Simple mode session")
@MainActor
struct SimpleModeSessionTests {
    private func session() -> SimpleModeSession {
        SimpleModeSession(template: FilmTemplateCatalog.companyIntro)
    }

    private func spec() throws -> JSONRenderSpec {
        try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": { "page": { "type": "Stack", "props": {}, "children": [] } }
        }
        """)
    }

    private func choices(_ count: Int) -> [TemplateChoice] {
        (0..<count).map {
            TemplateChoice(id: "item-\($0)", title: "Template \($0)", summary: "", reason: "fits")
        }
    }

    @Test("The wizard starts on the engine page")
    func startsOnEngine() {
        let session = session()
        #expect(session.step == .chooseEngine)
        #expect(session.step.wizardStep == .engine)
        #expect(session.backend == nil)
        #expect(!session.canRefine)
    }

    @Test("Choosing an engine records it and moves on to the brief")
    func choosingAnEngine() {
        let session = session()
        session.chooseEngine(.claudeCode)
        #expect(session.backend == .claudeCode)
        #expect(session.step == .intake)
        #expect(session.step.wizardStep == .intake)

        // Back to the first page keeps the pick, so returning does not silently
        // reset the run to the app default.
        session.returnToEngine()
        #expect(session.step == .chooseEngine)
        #expect(session.backend == .claudeCode)
    }

    @Test("Progress cannot be reported before the wizard has started")
    func progressNeedsARun() {
        let session = session()
        #expect(throws: SimpleModeError.self) { try session.report(progress: "reading") }
        session.chooseEngine(nil)
        #expect(throws: SimpleModeError.self) { try session.report(progress: "reading") }
    }

    @Test("The location step preserves the brief and chosen path when going back")
    func locationKeepsBrief() throws {
        let session = session()
        session.chooseEngine(.codex)
        let brief = IntakeSubmission(formValues: ["projectName": "Acme", "website": "acme.com", "uploads": ["/tmp/shot.mov"]])
        session.reviewLocation(for: brief)
        #expect(session.step == .chooseLocation)
        #expect(session.step.wizardStep == .location)
        #expect(session.document == nil)
        #expect(session.destinationURL == nil)
        #expect(throws: SimpleModeError.self) { try session.report(progress: "reading") }
        let chosen = URL(fileURLWithPath: "/tmp/My Films/Acme.rxfilmstudio")
        session.chooseDestination(chosen)
        session.returnToBrief()
        #expect(session.intake?.uploads == brief.uploads)
        #expect(session.backend == .codex)
        session.reviewLocation(for: brief)
        #expect(session.destinationURL == chosen)
    }

    @Test("No film is created until a destination is selected")
    func creationNeedsLocation() async {
        let session = session()
        let brief = IntakeSubmission(formValues: ["projectName": "No destination"])
        session.reviewLocation(for: brief)
        await SimpleModeCoordinator.shared.submitIntake(brief, for: session)
        #expect(session.document == nil)
        #expect(session.thread == nil)
        #expect(session.step == .chooseLocation)
    }

    @Test("An occupied destination keeps the existing file and lets the user choose again")
    func occupiedLocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WizardLocation-\(UUID())")
        let chosen = root.appendingPathComponent("Keep.rxfilmstudio")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let marker = chosen.appendingPathComponent("keep.txt")
        try "Existing film".write(to: marker, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = session()
        let brief = IntakeSubmission(formValues: ["projectName": "Keep"])
        session.reviewLocation(for: brief)
        session.chooseDestination(chosen)
        await SimpleModeCoordinator.shared.submitIntake(brief, for: session)
        #expect(session.step == .chooseLocation)
        #expect(session.error != nil)
        #expect(session.document == nil)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "Existing film")
    }

    @Test("Templates are accepted during research and move the wizard on")
    func presentsTemplates() throws {
        let session = session()
        session.beginCreating()
        // Only reachable once research has begun; the session needs no film for
        // the state machine itself.
        session.step_forTesting(.researching)

        let message = try session.present(templates: choices(3), summary: "Acme sells boots.")
        #expect(message.contains("3 templates"))
        #expect(session.lastSummary == "Acme sells boots.")
        guard case .chooseTemplate(let listed) = session.step else {
            Issue.record("expected chooseTemplate, got \(session.step)")
            return
        }
        #expect(listed.count == 3)
        #expect(session.step.wizardStep == .chooseTemplate)
    }

    @Test("An empty candidate list is refused with a fixable message")
    func rejectsEmptyTemplates() {
        let session = session()
        session.step_forTesting(.researching)
        #expect(throws: SimpleModeError.self) {
            try session.present(templates: [], summary: nil)
        }
    }

    @Test("An empty catalog leaves research with a way out")
    func skipsTemplatesWhenNoneFit() throws {
        let session = session()
        session.step_forTesting(.researching)
        // The deadlock this replaces: present(templates:) refuses an empty list
        // and options do not belong in research, so a catalog with no project
        // templates left the agent no legal move at all.
        let message = try session.skipTemplates(reason: "The marketplace has no project templates yet.")
        #expect(message.contains("Stop now"))
        guard case .templatesUnavailable(let reason) = session.step else {
            Issue.record("expected templatesUnavailable, got \(session.step)")
            return
        }
        #expect(reason == "The marketplace has no project templates yet.")
        #expect(session.step.wizardStep == .chooseTemplate)
    }

    @Test("Skipping templates without a reason still reads as a sentence")
    func skipTemplatesSuppliesAReason() throws {
        let session = session()
        session.step_forTesting(.researching)
        try session.skipTemplates(reason: "   ")
        guard case .templatesUnavailable(let reason) = session.step else {
            Issue.record("expected templatesUnavailable, got \(session.step)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("Templates cannot be skipped once the build is under way")
    func skipTemplatesRespectsThePhase() {
        let session = session()
        session.step_forTesting(.building)
        #expect(throws: SimpleModeError.self) {
            try session.skipTemplates(reason: "too late")
        }
        #expect(session.step == .building)
    }

    @Test("Planning with no template leaves the build without one")
    func planningWithoutATemplate() {
        let session = session()
        session.step_forTesting(.templatesUnavailable("nothing fitted"))
        session.beginPlanning(with: nil)
        #expect(session.chosenTemplate == nil)
        #expect(session.step == .planning)
    }

    @Test("A tool that arrives in the wrong phase is refused, not applied")
    func rejectsOutOfPhase() throws {
        let session = session()
        // Options during research would replace the page the user is reading.
        session.step_forTesting(.researching)
        #expect(throws: SimpleModeError.self) {
            try session.present(spec: try spec(), title: nil, initialState: nil)
        }
        #expect(session.step == .researching)

        session.step_forTesting(.building)
        #expect(throws: SimpleModeError.self) {
            try session.present(templates: choices(1), summary: nil)
        }
    }

    @Test("Options seed once, so a re-present keeps the user's answers")
    func keepsAnswersAcrossRepresent() throws {
        let session = session()
        session.step_forTesting(.planning)
        _ = try session.present(
            spec: try spec(),
            title: "Choose",
            initialState: .object(["style": .object(["captions": .bool(true)])])
        )
        #expect(session.optionsState.value(at: "/style/captions")?.bool == true)

        session.optionsState.set(.bool(false), at: "/style/captions")
        _ = try session.present(
            spec: try spec(),
            title: "Choose",
            initialState: .object(["style": .object(["captions": .bool(true)])])
        )
        #expect(session.optionsState.value(at: "/style/captions")?.bool == false)
    }

    @Test("A dangling child id is reported back so the agent can fix it")
    func reportsDanglingChildren() throws {
        let session = session()
        session.step_forTesting(.planning)
        let spec = try JSONRenderSpec.decode(json: """
        {
          "root": "page",
          "elements": { "page": { "type": "Stack", "children": ["ghost"] } }
        }
        """)
        let message = try session.present(spec: spec, title: nil, initialState: nil)
        #expect(message.contains("ghost"))
    }

    @Test("Two unusable specs and the wizard offers to continue without them")
    func fallsBackAfterTwoBadSpecs() {
        let session = session()
        session.step_forTesting(.planning)
        #expect(session.recordRejectedOptions("bad") == false)
        #expect(session.recordRejectedOptions("bad again") == true)
        guard case .optionsUnavailable = session.step else {
            Issue.record("expected optionsUnavailable, got \(session.step)")
            return
        }
    }

    @Test("Progress becomes the status line, but not before the run starts")
    func progress() throws {
        let session = session()
        #expect(throws: SimpleModeError.self) { try session.report(progress: "Reading…") }

        session.step_forTesting(.building)
        _ = try session.report(progress: "  Placing a clip…  ")
        #expect(session.statusText == "Placing a clip…")
        // An empty report clears the line rather than showing a blank one.
        _ = try session.report(progress: "   ")
        #expect(session.statusText == nil)
    }

    @Test("A bad spec outside the options phase does not hijack the page")
    func rejectedOptionsRespectThePhase() {
        let session = session()
        session.step_forTesting(.chooseTemplate(choices(2)))
        // Two malformed specs sent while the user is picking a template must
        // not replace that page with a fallback that has no template to build.
        #expect(session.recordRejectedOptions("bad") == false)
        #expect(session.recordRejectedOptions("bad again") == false)
        guard case .chooseTemplate = session.step else {
            Issue.record("the template page was replaced: \(session.step)")
            return
        }
    }

    @Test("A build only finishes once its own turn has run")
    func buildNeedsItsTurn() {
        let session = session()
        session.step_forTesting(.planning)
        session.beginBuilding(selections: "{}")
        // `send` returns before the agent reports busy, and earlier phases may
        // already have left clips behind, so "not running" alone must not end
        // the build.
        #expect(!session.turnHasStarted)
        session.noteAgentRunning(false)
        #expect(!session.turnHasStarted)
        session.noteAgentRunning(true)
        #expect(session.turnHasStarted)
        #expect(session.isAgentRunning)
    }

    @Test("A failed phase can be cleared so the user can try again")
    func clearsError() {
        let session = session()
        session.step_forTesting(.researching)
        session.error = "The engine timed out."
        session.statusText = "Reading the website…"
        session.clearError()
        #expect(session.error == nil)
        #expect(session.statusText == nil)
        // Clearing an error does not move the wizard; the retry re-runs the
        // same phase.
        #expect(session.step == .researching)
    }

    @Test("Refining is offered once there is something to refine")
    func refineWindow() {
        let session = session()
        session.step_forTesting(.researching)
        #expect(!session.canRefine)
        session.step_forTesting(.building)
        #expect(session.canRefine)
        session.finishBuilding(summary: "A 30-second intro.")
        #expect(session.step == .preview)
        #expect(session.canRefine)
        #expect(session.lastSummary == "A 30-second intro.")
    }
}

@Suite("Simple mode film naming")
@MainActor
struct SimpleModeNamingTests {
    private var moviesDirectory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    @Test("A brief's name becomes a package beside the user's other films")
    func createsInMovies() throws {
        let name = "SimpleModeTest \(UUID().uuidString.prefix(8))"
        let document = try SimpleModeCoordinator.shared.createDocument(named: name)
        defer {
            let url = document.packageURL
            Task { await ProjectDocumentController.shared.close(document) }
            try? FileManager.default.removeItem(at: url)
        }
        #expect(document.packageURL.pathExtension == "rxfilmstudio")
        #expect(document.packageURL.deletingLastPathComponent().path == moviesDirectory.path)
        #expect(document.displayName == name)
    }

    @Test("A second film with the same name gets a suffix instead of failing")
    func deduplicatesNames() throws {
        let name = "SimpleModeDup \(UUID().uuidString.prefix(8))"
        let first = try SimpleModeCoordinator.shared.createDocument(named: name)
        let second = try SimpleModeCoordinator.shared.createDocument(named: name)
        defer {
            let urls = [first.packageURL, second.packageURL]
            Task {
                await ProjectDocumentController.shared.close(first)
                await ProjectDocumentController.shared.close(second)
            }
            urls.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        #expect(first.packageURL != second.packageURL)
        #expect(second.displayName == "\(name) 2")
    }

    @Test("A name with a path separator stays one file in Movies")
    func flattensSeparators() throws {
        let token = UUID().uuidString.prefix(8)
        let document = try SimpleModeCoordinator.shared.createDocument(named: "SimpleMode/\(token)")
        defer {
            let url = document.packageURL
            Task { await ProjectDocumentController.shared.close(document) }
            try? FileManager.default.removeItem(at: url)
        }
        // Not a file inside a "SimpleMode" folder that was never created.
        #expect(document.packageURL.deletingLastPathComponent().path == moviesDirectory.path)
        #expect(document.displayName == "SimpleMode-\(token)")
    }
}
