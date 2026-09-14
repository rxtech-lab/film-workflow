import SwiftUI

struct MarketplaceDescriptionSection: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            MarketplaceSectionHeading(title: "Description", symbol: "text.alignleft", tint: .secondary)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .modifier(MarketplaceDetailSurface())
    }
}

/// A readable excerpt is always visible; expansion reveals the original text.
struct MarketplacePromptSection: View {
    let title: LocalizedStringKey
    let prompt: String
    @State private var isExpanded = false

    private var hasMore: Bool { prompt.count > 280 }
    private var displayedPrompt: String {
        guard hasMore, !isExpanded else { return prompt }
        let prefix = String(prompt.prefix(280))
        let end = prefix.lastIndex(where: { $0.isWhitespace }) ?? prefix.endIndex
        return String(prefix[..<end]).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            MarketplaceSectionHeading(title: title, symbol: "text.quote", tint: .purple)
            Text(displayedPrompt)
                .font(.body)
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.purple.opacity(0.35))
                        .frame(width: 3)
                }
            if hasMore {
                Button { isExpanded.toggle() } label: {
                    HStack(spacing: 6) {
                        Text(isExpanded ? "Show less" : "Read full prompt")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.callout.weight(.medium))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("marketplace-prompt-expand")
            }
        }
        .padding(22)
        .modifier(MarketplaceDetailSurface(tint: .purple))
        .onChange(of: prompt) { isExpanded = false }
    }
}

/// Detail-page sections keep footage, creative direction and dependencies distinct.
/// The compact presentation used by agent cards remains in MarketplaceTemplateDetails.
struct MarketplaceTemplateSections: View {
    let item: MarketplaceItem
    let definition: ProjectTemplateDefinition?

    private var requirements: [ProjectTemplateDefinition.Requirement] {
        definition?.footageRequirements ?? item.metadata.template?.footageRequirements ?? []
    }

    private var dependencies: [ProjectTemplateDefinition.Dependency] {
        definition?.marketplaceItems ?? item.metadata.template?.marketplaceItems ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let prompt = definition?.prompt ?? item.metadata.promptExcerpt, !prompt.isEmpty {
                MarketplacePromptSection(title: "Project prompt", prompt: prompt)
            }
            if !requirements.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        MarketplaceSectionHeading(title: "Footage to provide", symbol: "photo.on.rectangle.angled", tint: .cyan)
                        Spacer(minLength: 8)
                        Text(requirements.count.formatted())
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.primary.opacity(0.06), in: .capsule)
                    }
                    ForEach(requirements) { requirement in
                        MarketplaceFootageRequirementCard(requirement: requirement)
                    }
                }
            }
            if let definition, !definition.shots.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceSectionHeading(title: "Shot plan", symbol: "film.stack", tint: .orange)
                    DisclosureGroup("\(definition.shots.count) shots · \(definition.videoStyle)") {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(definition.shots) { shot in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(shot.title).font(.callout.weight(.semibold))
                                        Spacer()
                                        Text("\(shot.durationSeconds.formatted())s")
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                    Text(shot.instructions).font(.callout).foregroundStyle(.secondary)
                                        .lineSpacing(4).textSelection(.enabled)
                                }
                            }
                            if !definition.editingGuidance.isEmpty {
                                Text(definition.editingGuidance).font(.callout).foregroundStyle(.secondary)
                                    .lineSpacing(4).textSelection(.enabled)
                            }
                        }
                        .padding(.top, 14)
                    }
                }
                .padding(22)
                .modifier(MarketplaceDetailSurface())
            }
            if !dependencies.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    MarketplaceSectionHeading(title: "Marketplace items", symbol: "bag", tint: .blue)
                    ForEach(dependencies) { reference in
                        MarketplaceDependencyRow(reference: reference)
                    }
                }
                .padding(22)
                .modifier(MarketplaceDetailSurface())
            }
        }
    }
}

private struct MarketplaceFootageRequirementCard: View {
    let requirement: ProjectTemplateDefinition.Requirement

    private var symbol: String {
        switch requirement.mediaType {
        case "image": return "photo"
        case "audio": return "waveform"
        default: return "video"
        }
    }

    private var mediaLabel: String {
        switch requirement.mediaType {
        case "image": return String(localized: "Image")
        case "audio": return String(localized: "Audio")
        case "video": return String(localized: "Video")
        default: return requirement.mediaType.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.cyan)
                    .frame(width: 42, height: 42)
                    .background(.cyan.opacity(0.10), in: .rect(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(requirement.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mediaLabel).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(requirement.required ? "Required" : "Optional")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(requirement.required ? Color.accentColor : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(requirement.required ? Color.accentColor.opacity(0.12) : .primary.opacity(0.06), in: .capsule)
                    .fixedSize()
            }
            if !requirement.instructions.isEmpty {
                Text(requirement.instructions)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .modifier(MarketplaceDetailSurface())
    }
}

private struct MarketplaceSectionHeading: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(title).font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .foregroundStyle(tint)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

/// Content uses a quiet material surface; Liquid Glass stays on floating controls.
private struct MarketplaceDetailSurface: ViewModifier {
    var tint: Color = .clear

    func body(content: Content) -> some View {
        content
            .background(.thinMaterial, in: .rect(cornerRadius: 22))
            .background(tint.opacity(0.08), in: .rect(cornerRadius: 22))
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(LinearGradient(colors: [.primary.opacity(0.10), .primary.opacity(0.025)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
