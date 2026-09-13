import SwiftUI

/// Append cards with a new stable slug; previously seen cards stay read across updates.
struct WhatsNewFeature: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let imageName: String
    let highlights: [Highlight]

    struct Highlight {
        let icon: String
        let title: LocalizedStringKey
        let detail: LocalizedStringKey
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
    ]
}
