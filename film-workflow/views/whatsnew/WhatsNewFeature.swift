import SwiftUI

/// Append cards with a new stable slug; previously seen cards stay read across updates.
struct WhatsNewFeature: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let imageName: String
    let highlights: [Highlight]
    /// The button on the card's own page. Per card rather than fixed, so a card
    /// sends the user to the thing it is about.
    let callToAction: CallToAction

    init(
        id: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey,
        imageName: String,
        highlights: [Highlight],
        callToAction: CallToAction = .exploreMarketplace
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageName = imageName
        self.highlights = highlights
        self.callToAction = callToAction
    }

    struct Highlight {
        let icon: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
    }

    enum CallToAction {
        case exploreMarketplace
        case startNewFilm

        var label: LocalizedStringKey {
            switch self {
            case .exploreMarketplace: "Explore Marketplace"
            case .startNewFilm: "Start a Film"
            }
        }

        var systemImage: String {
            switch self {
            case .exploreMarketplace: "storefront"
            case .startNewFilm: "sparkles"
            }
        }
    }

    static let all: [WhatsNewFeature] = [
        WhatsNewFeature(
            id: "marketplace-and-rxfilm-subscription",
            title: "Marketplace is here",
            subtitle: "A world of creative assets for your next film.",
            imageName: "WhatsNewMarketplace",
            highlights: [
                Highlight(
                    icon: "storefront",
                    title: "Find your next inspiration",
                    detail: "Browse footage, music, sound effects, fonts, transitions, effects and Remotion prompts."
                ),
                Highlight(
                    icon: "square.and.arrow.down",
                    title: "Install once. Create in any film.",
                    detail: "Keep assets in your shared library and add installed media to any film."
                ),
                Highlight(
                    icon: "sparkles",
                    title: "RxFilm subscription service",
                    detail: "Sign in with RxLab and choose RxFilm credits in AI Provider settings. Use credits for supported AI models and paid marketplace assets."
                ),
            ]
        ),
        WhatsNewFeature(
            id: "marketplace-project-templates",
            title: "Project templates are here",
            subtitle: "A head start for your next film.",
            imageName: "WhatsNewProjectTemplates",
            highlights: [
                Highlight(
                    icon: "rectangle.stack",
                    title: "Start with a shot plan",
                    detail: "Browse Marketplace templates with a video style, ordered shots and editing guidance."
                ),
                Highlight(
                    icon: "sparkles",
                    title: "Make it yours with the agent",
                    detail: "Match your footage to each shot and get help generating missing clips."
                ),
                Highlight(
                    icon: "film.stack",
                    title: "Build a new sequence",
                    detail: "Apply a template to a new sequence in your current film, then refine the edit."
                ),
            ]
        ),
        WhatsNewFeature(
            id: "simple-mode-guided-creation",
            title: "Simple mode",
            subtitle: "Answer a few questions. Get a first cut.",
            imageName: "WhatsNewSimpleModeGenerated",
            highlights: [
                Highlight(
                    icon: "square.grid.2x2",
                    title: "Start from a template",
                    detail: "New Film opens a gallery of guided starting points. Company intro video is first; more are coming."
                ),
                Highlight(
                    icon: "globe",
                    title: "Built from your website and your footage",
                    detail: "Give us your site, a sentence about the film and any clips you have. We find a matching template and ask how it should look."
                ),
                Highlight(
                    icon: "play.rectangle",
                    title: "Watch it come together",
                    detail: "The preview follows along as each shot lands. Ask for changes in plain words, then open it in the full editor."
                ),
            ],
            callToAction: .startNewFilm
        ),
    ]
}
