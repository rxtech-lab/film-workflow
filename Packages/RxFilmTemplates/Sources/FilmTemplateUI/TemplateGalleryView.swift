import FilmTemplateKit
import SwiftUI

/// The page "New Film" lands on: guided templates by group, plus the escape
/// hatch to the old empty-film flow.
public struct TemplateGalleryView: View {
    let groups: [(group: FilmTemplateGroup, templates: [FilmTemplate])]
    let onPick: (FilmTemplate) -> Void
    let onBlank: () -> Void

    public init(
        groups: [(group: FilmTemplateGroup, templates: [FilmTemplate])] = FilmTemplateCatalog.grouped,
        onPick: @escaping (FilmTemplate) -> Void,
        onBlank: @escaping () -> Void
    ) {
        self.groups = groups
        self.onPick = onPick
        self.onBlank = onBlank
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                    .templateTip(.gallery)

                ForEach(groups, id: \.group) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(LocalizedStringKey(entry.group.title))
                                .font(.system(size: 15, weight: .semibold))
                            Text(LocalizedStringKey(entry.group.summary))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 250), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(entry.templates) { template in
                                TemplateGalleryCard(template: template) {
                                    FilmTemplateTip.gallery.didPerform()
                                    onPick(template)
                                }
                            }
                        }
                    }
                }

                Divider()
                BlankFilmCard(action: onBlank)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("new-film.gallery")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Start a new film")
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Pick a starting point. We'll ask a few questions, then build a first cut you can refine in the editor.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct TemplateGalleryCard: View {
    let template: FilmTemplate
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: template.systemImage)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 46, height: 46)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                    .accessibilityHidden(true)

                Text(LocalizedStringKey(template.title))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(template.summary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                Label("Guided", systemImage: "sparkles")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 168, alignment: .leading)
            .padding(14)
            .background(
                Color.primary.opacity(isHovered ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.06))
            }
            .contentShape(RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("new-film.template.\(template.id)")
    }
}

struct BlankFilmCard: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "film")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Blank film")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Start with an empty timeline and build it yourself.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                Color.primary.opacity(isHovered ? 0.06 : 0.025),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityIdentifier("new-film.blank")
    }
}
