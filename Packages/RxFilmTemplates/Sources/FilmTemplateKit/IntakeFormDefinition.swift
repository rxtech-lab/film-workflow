import Foundation

/// The first page's form, as JSON Schema plus a uiSchema.
///
/// Kept as JSON text rather than a built schema so this target stays free of
/// the schema DSL — the UI target decodes it, and a test can assert on the
/// text without a window.
public struct IntakeFormDefinition: Hashable, Sendable {
    public let schemaJSON: String
    public let uiSchemaJSON: String

    public init(schemaJSON: String, uiSchemaJSON: String) {
        self.schemaJSON = schemaJSON
        self.uiSchemaJSON = uiSchemaJSON
    }

    /// Field names shared by the schema, the form reader and the prompts.
    public enum Field {
        public static let projectName = "projectName"
        public static let website = "website"
        public static let description = "description"
        public static let uploads = "uploads"
    }

    /// The widget name the app registers for file selection. JSONSchemaForm has
    /// no file field of its own, so the wizard supplies one.
    public static let filePickerWidget = "file-picker"
    public static let websiteWidget = "website"

    public static let companyIntro = IntakeFormDefinition(
        schemaJSON: """
        {
          "type": "object",
          "title": "Tell us about the company",
          "properties": {
            "projectName": {
              "type": "string",
              "title": "Film name",
              "description": "Choose where to save your film in the next step.",
              "minLength": 1
            },
            "website": {
              "type": "string",
              "title": "Company website",
              "format": "uri",
              "description": "We read the site to learn the company's story, tone and colours."
            },
            "description": {
              "type": "string",
              "title": "What should this film say?",
              "description": "Audience, the one message to land, anything the site does not cover."
            },
            "uploads": {
              "type": "array",
              "title": "Your footage",
              "description": "Logos, product shots, office clips, music. Optional — we can fill gaps from the marketplace.",
              "items": { "type": "string" }
            }
          },
          "required": ["projectName", "website"]
        }
        """,
        uiSchemaJSON: """
        {
          "ui:order": ["projectName", "website", "description", "uploads"],
          "projectName": {
            "ui:placeholder": "Acme intro"
          },
          "website": {
            "ui:widget": "website",
            "ui:placeholder": "https://acme.com"
          },
          "description": {
            "ui:widget": "textarea",
            "ui:placeholder": "A 30-second intro for the homepage, aimed at first-time visitors."
          },
          "uploads": {
            "ui:widget": "file-picker",
            "ui:options": {
              "accept": ["video", "image", "audio"]
            }
          }
        }
        """
    )
}

/// What the user filled in, read back out of the form.
public struct IntakeSubmission: Hashable, Sendable {
    public var projectName: String
    public var website: URL?
    public var websiteText: String
    public var description: String
    public var uploads: [URL]

    public init(
        projectName: String,
        website: URL?,
        websiteText: String,
        description: String,
        uploads: [URL]
    ) {
        self.projectName = projectName
        self.website = website
        self.websiteText = websiteText
        self.description = description
        self.uploads = uploads
    }

    /// Reads a submission out of the dictionary the form hands back.
    public init(formValues: [String: Any]) {
        func text(_ key: String) -> String {
            (formValues[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let website = text(IntakeFormDefinition.Field.website)
        let paths = (formValues[IntakeFormDefinition.Field.uploads] as? [Any])?
            .compactMap { $0 as? String } ?? []

        self.init(
            projectName: text(IntakeFormDefinition.Field.projectName),
            website: Self.normalizedURL(website),
            websiteText: website,
            description: text(IntakeFormDefinition.Field.description),
            uploads: paths.compactMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: path)
            }
        )
    }

    /// Accepts what a person types. `acme.com` is a website; `URL(string:)`
    /// alone would take it as a relative path and produce nothing fetchable.
    public static func normalizedURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(), !host.isEmpty,
              url.user() == nil, url.password() == nil,
              url.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        return url
    }

    /// A film name derived from the site, used until the user types their own.
    public static func suggestedName(for website: String) -> String? {
        guard let host = normalizedURL(website)?.host() else { return nil }
        let label = host
            .replacingOccurrences(of: "www.", with: "")
            .split(separator: ".")
            .first
            .map(String.init) ?? host
        guard !label.isEmpty else { return nil }
        return label.prefix(1).uppercased() + label.dropFirst() + " intro"
    }
}
