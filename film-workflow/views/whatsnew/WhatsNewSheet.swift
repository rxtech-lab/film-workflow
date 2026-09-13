import SwiftUI

/// RxCode's feature-card structure, with illustration artwork and native app styling.
struct WhatsNewSheet: View {
    let features: [WhatsNewFeature]
    let onSeen: (WhatsNewFeature) -> Void
    let onDismiss: () -> Void
    let onExploreMarketplace: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedIndex = 0
    @State private var isMovingForward = true

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                ZStack {
                    if features.indices.contains(selectedIndex) {
                        featureCard(features[selectedIndex])
                            .id(features[selectedIndex].id)
                            .transition(cardTransition)
                            .onAppear { onSeen(features[selectedIndex]) }
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipped()

            footer
        }
        .frame(width: 560, height: 700)
        .background(.background)
        .onAppear {
            if features.isEmpty { onDismiss() }
        }
    }

    /// Cards slide in the direction of travel; Reduce Motion gets a plain cross-fade.
    private var cardTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let incoming: Edge = isMovingForward ? .trailing : .leading
        let outgoing: Edge = isMovingForward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity)
        )
    }

    private func page(to index: Int) {
        guard features.indices.contains(index), index != selectedIndex else { return }
        isMovingForward = index > selectedIndex
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.3)) {
            selectedIndex = index
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if selectedIndex > 0 {
                Button { page(to: selectedIndex - 1) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Back")
                .accessibilityLabel("Back")
                .accessibilityIdentifier("whats-new.back")
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("What's New")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("New in RxFilmStudio")
                    .font(.system(size: 20, weight: .bold))
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
            .accessibilityIdentifier("whats-new.close")
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private func featureCard(_ feature: WhatsNewFeature) -> some View {
        VStack(spacing: 18) {
            Image(feature.imageName)
                .resizable()
                .scaledToFit()
                .frame(height: 192)
                .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text(feature.title)
                    .font(.system(size: 26, weight: .semibold))
                    .accessibilityIdentifier("whats-new.title")
                Text(feature.subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(Array(feature.highlights.enumerated()), id: \.offset) { _, highlight in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: highlight.icon)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 24, height: 22)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(highlight.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(highlight.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            if features.count > 1 {
                HStack(spacing: 8) {
                    ForEach(features.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == selectedIndex ? Color.primary : Color.secondary.opacity(0.3))
                            .frame(width: index == selectedIndex ? 24 : 8, height: 6)
                    }
                }
                .accessibilityLabel("Feature \(selectedIndex + 1) of \(features.count)")
            }
            HStack(spacing: 12) {
                // Dismissing early is the close button's job; the last card offers it outright.
                if selectedIndex < features.count - 1 {
                    Button("Next") { page(to: selectedIndex + 1) }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("whats-new.next")
                } else {
                    Button("Got it", action: onDismiss)
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("whats-new.dismiss")

                    Button(action: onExploreMarketplace) {
                        Label("Explore Marketplace", systemImage: "storefront")
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("whats-new.explore")
                }
            }
            .controlSize(.large)
        }
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}

#Preview {
    WhatsNewSheet(features: WhatsNewFeature.all, onSeen: { _ in }, onDismiss: {}, onExploreMarketplace: {})
}
