import SwiftUI

/// A concrete row view keeps text, word decoding and context-menu construction
/// out of List's pass over every caption to discover identities and tags.
struct CaptionSegmentRow: View {
    enum Action { case edit, words, retime, translate, split, merge, delete }

    let project: CaptionProject
    let segment: CaptionSegment
    let index: Int
    let canMergeWithNext: Bool
    let resolver: CaptionTermResolver
    let rowIssues: [CaptionValidationIssue]
    let clipPlayer: CaptionClipPlayer
    let isTranslating: Bool
    let onAction: (Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 26, alignment: .trailing)

            CaptionClipPlayButton(
                url: project.audioURL,
                startMs: segment.startMs,
                endMs: segment.endMs,
                clipID: segment.uuid.uuidString,
                clipPlayer: clipPlayer
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(
                        "\(timestamp(segment.startMs))–\(timestamp(segment.endMs))"
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    if let label = project.speaker(segment.speakerId)?.label, !label.isEmpty {
                        Text(label)
                            .font(.caption)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(speakerTint(segment.speakerId).opacity(0.18), in: Capsule())
                    }

                    if segment.isEstimatedTiming {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("Timing is estimated")
                    }
                    if segment.hasWordTimings {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("\(segment.words.count) word timings")
                    }
                }

                Text(segment.text)
                    .accessibilityIdentifier("caption-editor-text.\(segment.uuid)")
                    .font(.body)
                    .textSelection(.enabled)

                translationLine(for: segment, resolver: resolver)

                ForEach(rowIssues) { issue in
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(issue.isBlocking ? .red : .orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onAction(.edit) }
        .contextMenu {
            Button("Edit Text & Timing…") { onAction(.edit) }
            if project.lyricsSourceID != nil {
                Button("Retime Lyrics…") { onAction(.retime) }
                Button("Translate Lyrics…") { onAction(.translate) }
                    .disabled(isTranslating)
            }
            Button("Word Timings…") { onAction(.words) }
                .disabled(segment.words.isEmpty && segment.text.isEmpty)
            Divider()
            Button("Split at Midpoint") { onAction(.split) }
                .disabled(segment.words.count < 2)
            Button("Merge with Next") { onAction(.merge) }
                .disabled(!canMergeWithNext)
            Divider()
            Button("Delete…", role: .destructive) { onAction(.delete) }
        }
        #if os(iOS)
        .swipeActions(edge: .trailing) {
            Button("Delete…", role: .destructive) { onAction(.delete) }
            Button("Edit") { onAction(.edit) }
                .tint(.blue)
        }
        .swipeActions(edge: .leading) {
            Button("Words") { onAction(.words) }
                .tint(.purple)
        }
        #endif
    }

    /// The selected translation, under the original.
    ///
    /// Secondary colour at `.callout` is what makes the original read as the
    /// primary text — a divider or an indent would fight the row metrics the
    /// timestamps and speaker chip already establish.
    @ViewBuilder
    private func translationLine(
        for segment: CaptionSegment,
        resolver: CaptionTermResolver
    ) -> some View {
        let code = project.displayedTranslationLanguage
        if !code.isEmpty {
            if let translation = segment.translation(code), !translation.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    // Rendered, not raw: `{{RxLab}}` is storage, and it resolves
                    // against the glossary every time the row is drawn — which
                    // is why editing a term's wording updates the list at once.
                    Text(resolver.render(translation.text, language: code))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if segment.isTranslationStale(code) {
                        Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("The caption changed after this was translated")
                    }
                }
            } else {
                Text("Not translated")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func timestamp(_ ms: Int) -> String {
        project.lyricsSourceID == nil ? CaptionExporter.shortTimestamp(ms) : CaptionExporter.vttTimestamp(ms)
    }

    private func speakerTint(_ id: UUID?) -> Color {
        guard let speaker = project.speaker(id) else { return .secondary }
        return CaptionSpeakerPalette.color(at: speaker.colorIndex)
    }
}
