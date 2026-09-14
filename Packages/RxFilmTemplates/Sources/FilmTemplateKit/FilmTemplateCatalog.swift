import Foundation

/// The guided templates the New Film gallery offers.
///
/// One entry today. Adding a template means adding a case here with its own
/// intake form and prompt set; nothing else in the wizard changes.
public enum FilmTemplateCatalog {
    public static let companyIntro = FilmTemplate(
        id: "company-intro-video",
        group: .marketing,
        title: "Company intro video",
        summary: "A short film that introduces your company, built from your website and your footage.",
        systemImage: "building.2",
        marketplaceQueries: ["company intro", "brand story", "about us"],
        intake: .companyIntro,
        prompts: .companyIntro
    )

    public static let all: [FilmTemplate] = [companyIntro]

    /// Templates by group, in the group's declaration order, skipping empty
    /// groups so the gallery has no blank sections.
    public static var grouped: [(group: FilmTemplateGroup, templates: [FilmTemplate])] {
        FilmTemplateGroup.allCases.compactMap { group in
            let templates = all.filter { $0.group == group }
            return templates.isEmpty ? nil : (group, templates)
        }
    }

    public static func template(id: String) -> FilmTemplate? {
        all.first { $0.id == id }
    }
}
