import Foundation
import Testing
@testable import FilmTemplateKit

@Suite("Wizard prompts")
struct WizardPromptTests {
    /// The CLI engines see namespaced tool names; the prompt has to use
    /// whatever name that engine will actually be offered.
    private let prefixed: @Sendable (String) -> String = { "mcp__film_workflow__\($0)" }

    @Test("The system block teaches the phase protocol with the right tool names")
    func systemBlock() {
        let text = FilmTemplateCatalog.companyIntro.prompts.systemBlock(prefixed)
        #expect(text.contains("mcp__film_workflow__\(WizardTool.presentTemplates)"))
        #expect(text.contains("mcp__film_workflow__\(WizardTool.presentOptions)"))
        #expect(text.contains("mcp__film_workflow__\(WizardTool.reportProgress)"))
        #expect(text.contains("mcp__film_workflow__\(WebTool.read)"))
        // The spec reference is what keeps a small model's page renderable.
        #expect(text.contains("OptionGroup"))
        #expect(text.contains("$bindState"))
    }

    @Test("The research turn carries the brief and the uploads")
    func researchTurn() {
        let intake = IntakeSubmission(
            projectName: "Acme intro",
            website: URL(string: "https://acme.com"),
            websiteText: "acme.com",
            description: "Homepage film",
            uploads: []
        )
        let uploads = [
            WizardUploadDescription(sourceId: "imported:1", name: "office.mov", kind: "video", durationSeconds: 12),
        ]
        let text = FilmTemplateCatalog.companyIntro.prompts.research(
            intake, uploads, FilmTemplateCatalog.companyIntro.marketplaceQueries, { $0 }
        )
        #expect(text.contains("https://acme.com"))
        #expect(text.contains("Homepage film"))
        #expect(text.contains("imported:1"))
        #expect(text.contains("office.mov"))
        #expect(text.contains(WebTool.read))
        #expect(text.contains(WizardTool.presentTemplates))
        #expect(text.contains("company intro"))
    }

    @Test("With no uploads the agent is told to lean on the marketplace")
    func researchWithoutUploads() {
        let intake = IntakeSubmission(
            projectName: "Acme", website: nil, websiteText: "acme.com", description: "", uploads: []
        )
        let text = FilmTemplateCatalog.companyIntro.prompts.research(intake, [], ["company intro"], { $0 })
        #expect(text.contains("uploaded no footage"))
    }

    @Test("Plan, build and refine name the tools they need")
    func laterTurns() {
        let prompts = FilmTemplateCatalog.companyIntro.prompts
        let plan = prompts.planOptions("item-1", "Bold Brand Intro", { $0 })
        #expect(plan.contains("item-1"))
        #expect(plan.contains("Bold Brand Intro"))
        #expect(plan.contains(WizardTool.presentOptions))
        #expect(plan.contains("footage_list"))

        let build = prompts.build("item-1", #"{"footage":{"hero":"imported:1"}}"#, { $0 })
        #expect(build.contains("project_template_apply"))
        #expect(build.contains("imported:1"))
        #expect(build.contains("application_id"))

        let refine = prompts.refine("make it shorter", { $0 })
        #expect(refine.contains("make it shorter"))
        #expect(refine.contains("Do not create"))
    }
}
