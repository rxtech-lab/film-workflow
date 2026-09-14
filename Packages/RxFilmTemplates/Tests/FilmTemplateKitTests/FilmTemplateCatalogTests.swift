import Foundation
import Testing
@testable import FilmTemplateKit

@Suite("Template catalog")
struct FilmTemplateCatalogTests {
    @Test("The gallery has the company intro template, in a group")
    func catalog() {
        let template = FilmTemplateCatalog.template(id: "company-intro-video")
        #expect(template?.group == .marketing)
        #expect(template?.title == "Company intro video")
        #expect(FilmTemplateCatalog.grouped.contains { $0.group == .marketing })
        // Empty groups would render as blank sections in the gallery.
        #expect(FilmTemplateCatalog.grouped.allSatisfy { !$0.templates.isEmpty })
        #expect(FilmTemplateCatalog.all.map(\.id).count == Set(FilmTemplateCatalog.all.map(\.id)).count)
    }

    @Test("The intake schema is valid JSON with the fields the wizard reads")
    func intakeSchema() throws {
        let definition = FilmTemplateCatalog.companyIntro.intake
        let schema = try JSONSerialization.jsonObject(
            with: #require(definition.schemaJSON.data(using: .utf8))
        ) as? [String: Any]
        let properties = try #require(schema?["properties"] as? [String: Any])
        for field in [
            IntakeFormDefinition.Field.projectName,
            IntakeFormDefinition.Field.website,
            IntakeFormDefinition.Field.description,
            IntakeFormDefinition.Field.uploads,
        ] {
            #expect(properties[field] != nil, "schema is missing \(field)")
        }
        let required = schema?["required"] as? [String]
        #expect(required?.contains(IntakeFormDefinition.Field.projectName) == true)
        #expect(required?.contains(IntakeFormDefinition.Field.website) == true)

        let uiSchema = try JSONSerialization.jsonObject(
            with: #require(definition.uiSchemaJSON.data(using: .utf8))
        ) as? [String: Any]
        let uploads = uiSchema?[IntakeFormDefinition.Field.uploads] as? [String: Any]
        #expect(uploads?["ui:widget"] as? String == IntakeFormDefinition.filePickerWidget)
        let website = uiSchema?[IntakeFormDefinition.Field.website] as? [String: Any]
        #expect(website?["ui:widget"] as? String == IntakeFormDefinition.websiteWidget)
    }
}

@Suite("Intake submission")
struct IntakeSubmissionTests {
    @Test("Reads the form's values, including the file list")
    func readsForm() {
        let submission = IntakeSubmission(formValues: [
            "projectName": "  Acme intro  ",
            "website": "acme.com",
            "description": "Homepage film",
            "uploads": ["/tmp/a.mov", "/tmp/b.png", 7],
        ])
        #expect(submission.projectName == "Acme intro")
        #expect(submission.website?.absoluteString == "https://acme.com")
        #expect(submission.uploads.map(\.lastPathComponent) == ["a.mov", "b.png"])
    }

    @Test("A bare host is still a website")
    func normalizesURL() {
        #expect(IntakeSubmission.normalizedURL("acme.com")?.scheme == "https")
        #expect(IntakeSubmission.normalizedURL("https://acme.com/about")?.host() == "acme.com")
        #expect(IntakeSubmission.normalizedURL("   ") == nil)
        #expect(IntakeSubmission.normalizedURL("  acme.com/about  ")?.absoluteString == "https://acme.com/about")
        #expect(IntakeSubmission.normalizedURL("http://localhost:8080")?.absoluteString == "http://localhost:8080")
    }

    @Test("Invalid addresses and non-web schemes cannot be checked or opened", arguments: [
        "not a website", "https://", "https:///about", "https://exa mple.com",
        "file:///tmp/company.html", "ftp://acme.com", "javascript:alert(1)",
        "mailto:hello@acme.com", "https://user:password@acme.com", "https://acme.com:99999",
    ])
    func rejectsInvalidURL(_ text: String) {
        #expect(IntakeSubmission.normalizedURL(text) == nil)
    }

    @Test("The film name is suggested from the site")
    func suggestsName() {
        #expect(IntakeSubmission.suggestedName(for: "https://www.acme.com") == "Acme intro")
        #expect(IntakeSubmission.suggestedName(for: "acme.co.uk") == "Acme intro")
        #expect(IntakeSubmission.suggestedName(for: "") == nil)
    }
}
