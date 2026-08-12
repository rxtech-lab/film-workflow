import SwiftData
import SwiftUI

/// Reviews a batch of AI-proposed caption changes before any of them is written.
///
/// The same sheet serves all three AI tasks — splitting, glossary corrections
/// and conversational edits — because they all produce a `CaptionEditProposal`.
/// Selection accumulates in a draft and is written in one pass on apply, the
/// `CaptionRetimeSheet` pattern.
struct CaptionAIReviewSheet: View {
    @Bindable var project: CaptionProject
    let proposal: CaptionEditProposal
    /// Called with the number of changes actually written.
    var onApplied: ((Int) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// Items the user wants. Seeded from validation: anything flagged starts off.
    @State private var selected: Set<UUID> = []
    @State private var didSeed = false

    private var selectedItems: [CaptionEditProposalItem] {
        proposal.items.filter { selected.contains($0.id) }
    }

    private var flaggedCount: Int {
        proposal.items.count(where: { !$0.verdict.isOK })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if proposal.isEmpty {
                ContentUnavailableView(
                    "Nothing to Change",
                    systemImage: "checkmark.circle",
                    description: Text("The model didn't find anything worth changing.")
                )
                .frame(maxHeight: .infinity)
            } else {
                itemList
            }
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 520)
        // A reviewed selection is real work; don't let a stray Escape discard it.
        .interactiveDismissDisabled()
        .onAppear(perform: seedSelection)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Review AI Changes")
                    .font(.headline)
                // Which engine answered isn't cosmetic: the on-device model and
                // a hosted one make very different suggestions, and the engine
                // that ran isn't always the one in Settings — availability can
                // force a fallback.
                if !proposal.engine.isEmpty {
                    Text(proposal.engine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                        .help("The engine that produced these suggestions.")
                }
                Spacer()
                Text("\(selected.count) of \(proposal.items.count) selected")
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
            if !proposal.summary.isEmpty {
                Text(proposal.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if flaggedCount > 0 {
                // Phrased without an interpolated English fragment ("suggestion"
                // vs "suggestions"): that resolves to a `%@` in the string
                // catalog and can't be translated sensibly. The exact count is
                // already in the line above.
                Label(
                    "Some suggestions need a closer look, so they start unselected.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(proposal.items) { item in
                    row(item)
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func row(_ item: CaptionEditProposalItem) -> some View {
        let isOn = selected.contains(item.id)

        HStack(alignment: .top, spacing: 10) {
            // A plain glyph button rather than `.toggleStyle(.checkbox)`, which
            // is macOS-only — this sheet ships on iOS too.
            Button {
                if isOn { selected.remove(item.id) } else { selected.insert(item.id) }
            } label: {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOn ? "Selected" : "Not selected")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if item.displayIndex > 0 {
                        Text("#\(item.displayIndex)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(CaptionExporter.shortTimestamp(item.startMs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(kindLabel(item.operation))
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                    // Which language, on its own chip: "Translation" alone
                    // doesn't say what is about to be overwritten, and a
                    // project can carry several at once.
                    if let language = translationLanguage(item.operation) {
                        Text(language)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }

                if !item.before.isEmpty {
                    Text(item.before)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .strikethrough(isDestructive(item.operation), color: .secondary)
                }
                if !item.after.isEmpty {
                    Label(item.after, systemImage: "arrow.turn.down.right")
                        .font(.callout)
                        .labelStyle(.titleAndIcon)
                }

                if !item.reason.isEmpty {
                    Text(item.reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !item.verdict.isOK {
                    Label(item.verdict.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isOn ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { selected.remove(item.id) } else { selected.insert(item.id) }
        }
    }

    private var footer: some View {
        HStack {
            Button("Select All") { selected = Set(proposal.items.map(\.id)) }
                .buttonStyle(.borderless)
                .disabled(proposal.isEmpty)
            Button("Select None") { selected.removeAll() }
                .buttonStyle(.borderless)
                .disabled(selected.isEmpty)

            Spacer()

            Button("Discard", role: .cancel) { dismiss() }
            Button("Apply \(selected.isEmpty ? "" : "(\(selected.count))")") { apply() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Derived

    private func kindLabel(_ operation: CaptionEditOperation) -> LocalizedStringKey {
        switch operation {
        case .split: return "Split"
        case .replaceText: return "Text"
        case .merge: return "Merge"
        case .setSpeaker: return "Speaker"
        case .retime: return "Timing"
        case .setTranslation: return "Translation"
        case .delete: return "Delete"
        }
    }

    /// The language code on a translation row, or nil for every other kind.
    private func translationLanguage(_ operation: CaptionEditOperation) -> String? {
        guard case .setTranslation(_, let language, _) = operation, !language.isEmpty else {
            return nil
        }
        return language
    }

    private func isDestructive(_ operation: CaptionEditOperation) -> Bool {
        if case .delete = operation { return true }
        return false
    }

    // MARK: - Actions

    /// Runs once. Guarded because `onAppear` fires again when the sheet is
    /// re-shown after a sub-sheet, and re-seeding would throw away the review.
    private func seedSelection() {
        guard !didSeed else { return }
        didSeed = true
        selected = Set(proposal.items.filter(\.isApplicableByDefault).map(\.id))
    }

    private func apply() {
        let count = CaptionEditApplier.apply(
            selectedItems,
            to: project,
            context: modelContext,
            engine: proposal.engine
        )
        onApplied?(count)
        dismiss()
    }
}
