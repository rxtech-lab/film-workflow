import FilmTemplateKit
import SwiftUI

/// The templates the agent found, for the user to pick one.
public struct TemplateChoiceView: View {
    let title: String
    let summary: String?
    let candidates: [TemplateChoice]
    let onChoose: (TemplateChoice) -> Void
    let onCancel: () -> Void

    @State private var selection: TemplateChoice.ID?

    public init(
        title: String,
        summary: String?,
        candidates: [TemplateChoice],
        onChoose: @escaping (TemplateChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.summary = summary
        self.candidates = candidates
        self.onChoose = onChoose
        self.onCancel = onCancel
    }

    public var body: some View {
        WizardShell(
            title: "Pick a template",
            subtitle: summary.map { LocalizedStringKey($0) } ?? "These fit what we found on your site and the footage you gave us.",
            current: .chooseTemplate,
            onCancel: onCancel
        ) {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280), spacing: 14)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(candidates) { candidate in
                        TemplateChoiceCard(
                            candidate: candidate,
                            isSelected: selection == candidate.id
                        ) {
                            selection = candidate.id
                        }
                    }
                }
                .padding(24)
            }
            .accessibilityIdentifier("wizard.templates")
        } footer: {
            Button("Use This Template") {
                guard let chosen = candidates.first(where: { $0.id == selection }) else { return }
                onChoose(chosen)
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
            .accessibilityIdentifier("wizard.templates.confirm")
        }
        .onAppear {
            // The agent ranked them, so the first is its recommendation.
            if selection == nil { selection = candidates.first?.id }
        }
    }
}

struct TemplateChoiceCard: View {
    let candidate: TemplateChoice
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                preview
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(candidate.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                    }

                    Label(candidate.reason, systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)

                    if !candidate.summary.isEmpty {
                        Text(candidate.summary)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }

                    HStack(spacing: 8) {
                        if let shots = candidate.shotCount {
                            metric("\(shots) shot\(shots == 1 ? "" : "s")", "rectangle.stack")
                        }
                        if let footage = candidate.footageCount {
                            metric("\(footage) clip\(footage == 1 ? "" : "s") needed", "photo.on.rectangle")
                        }
                        Spacer(minLength: 0)
                        if let badge = candidate.badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(isHovered ? 0.06 : 0.03),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.06))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("wizard.template.\(candidate.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func metric(_ text: String, _ symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder private var preview: some View {
        if let url = candidate.previewImageURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
                case .failure: previewPlaceholder
                default: ZStack { Color.primary.opacity(0.05); ProgressView().controlSize(.small) }
                }
            }
            .frame(height: 118)
            .frame(maxWidth: .infinity)
            .clipped()
        } else {
            previewPlaceholder.frame(height: 118).frame(maxWidth: .infinity)
        }
    }

    private var previewPlaceholder: some View {
        ZStack {
            Color.primary.opacity(0.06)
            Image(systemName: "rectangle.stack.badge.play")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}
