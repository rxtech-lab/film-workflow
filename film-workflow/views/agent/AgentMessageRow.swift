import RxAgentSDK
import SwiftUI
import Textual

/// One transcript row.
///
/// Renders an `AgentTranscriptItem` from the SDK, with two app-specific
/// departures from the stock row:
///
/// 1. **The tool card and its detail sheet** — the design carried over from the
///    Remotion chat view, which reads better than a bare line and now serves
///    every engine rather than only the OpenAI loop.
/// 2. **Caption proposals.** A successful `caption_propose_edits` call isn't
///    really a tool result, it is something waiting for the user. It is rendered
///    from the tool call itself rather than from a separate message kind, so it
///    appears the moment the call lands whichever engine made it.
struct AgentMessageRow: View {
    let item: AgentTranscriptItem
    let thread: AgentThread
    /// Opens the review sheet for a proposal. Handed the persisted row rather
    /// than the decoded proposal, because applying writes the outcome back onto
    /// it.
    var onReviewProposal: (AgentMessage) -> Void = { _ in }

    var body: some View {
        switch item.kind {
        case .message(let message):
            messageRow(message)
        case .transientGroup(let calls):
            // One container for the run of cards, so their glass title bars
            // blend into each other instead of each sampling on its own.
            GlassEffectContainer(spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(calls) { call in
                        toolRow(call)
                    }
                }
            }
        case .accessory:
            EmptyView()
        }
    }

    // MARK: - Message

    @ViewBuilder
    private func messageRow(_ message: RxAgentSDK.AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(message.blocks) { block in
                switch block {
                case .text(_, let text):
                    textBlock(text, role: message.role)
                case .thinking(_, let text):
                    thinkingBlock(text)
                case .toolCall(let call):
                    toolRow(call)
                }
            }
            if let error = message.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private func textBlock(_ text: String, role: AgentRole) -> some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else if role == .system {
            // Something the app did on the user's behalf — applying a reviewed
            // batch — not something either party said. It is still replayed to
            // the model, so the agent knows how the review went before it
            // answers again.
            Label(text, systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        } else if role == .user {
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
        } else {
            StructuredText(markdown: text)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func thinkingBlock(_ text: String) -> some View {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            EmptyView()
        } else {
            Label(text, systemImage: "brain")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Tool

    @ViewBuilder
    private func toolRow(_ call: AgentToolCall) -> some View {
        if let row = proposalRow(for: call) {
            proposalCard(row)
        } else {
            HStack(spacing: 0) {
                AgentToolCard(call: call)
                    .frame(maxWidth: 460, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// The persisted proposal row this call produced, if it produced one.
    ///
    /// Matched by project rather than by call id: a proposal arriving from a CLI
    /// engine reaches the app over HTTP, where the only identity both sides know
    /// is the project's.
    private func proposalRow(for call: AgentToolCall) -> AgentMessage? {
        guard MCPToolName.bare(call.name) == "caption_propose_edits",
              !call.isError, call.isComplete
        else { return nil }
        return thread.orderedMessages.last { $0.kindEnum == .proposal }
    }

    private func proposalCard(_ row: AgentMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(row.content.isEmpty ? "Proposed changes" : row.content)
            } icon: {
                Image(systemName: "checklist")
            }
            .font(.callout)

            if let proposal = row.proposal {
                // Reviewed once already: say what came of it, and let the user
                // go back in — the rest of the batch may still be waiting.
                if let applied = row.proposalAppliedCount {
                    Label {
                        Text(
                            applied == 0
                                ? "No changes applied."
                                : "Applied \(applied) of \(proposal.items.count)."
                        )
                    } icon: {
                        Image(systemName: applied == 0 ? "xmark.circle" : "checkmark.circle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(applied == 0 ? .secondary : Color.green)
                }

                Button(
                    row.proposalAppliedCount == nil
                        ? "Review \(proposal.items.count) change\(proposal.items.count == 1 ? "" : "s")…"
                        : "Review again…"
                ) {
                    onReviewProposal(row)
                }
                .buttonStyle(.bordered)
            } else {
                Text("This proposal can no longer be read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.secondary.opacity(0.10))
        )
    }
}

// MARK: - Tool card

private struct AgentToolCard: View {
    let call: AgentToolCall
    @State private var showDetails = false
    @State private var isHovered = false

    private static let maxDisplayChars = 200

    private enum Status { case pending, ok, failed }

    private var status: Status {
        guard call.isComplete else { return .pending }
        return call.isError ? .failed : .ok
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                detailRow
            }
            .background {
                // Only drawn when a second row exists — with the title alone the
                // glass edge is the card's edge, and a second outline doubles it.
                if detailText != nil {
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(Color.secondary.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                                .strokeBorder(accentColor.opacity(0.16), lineWidth: 0.5)
                        )
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: call.isComplete)
        .sheet(isPresented: $showDetails) {
            AgentToolDetailSheet(call: call)
        }
    }

    private static let radius: CGFloat = 12

    // MARK: - Title

    /// The tool name and its arguments, on liquid glass tinted by the call's
    /// outcome. The glass carries the card's edge, so the shape closes off its
    /// bottom corners only when a result line sits underneath it.
    private var titleRow: some View {
        HStack(spacing: 8) {
            iconView

            Text(MCPToolName.bare(call.name))
                .font(.caption.weight(.semibold))
                .monospaced()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let args = compactArgs, !args.isEmpty {
                Text(truncate(args))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(
            .regular.tint(accentColor.opacity(isHovered ? 0.24 : 0.11)).interactive(),
            in: titleShape
        )
    }

    private var titleShape: UnevenRoundedRectangle {
        let bottom: CGFloat = detailText == nil ? Self.radius : 0
        return UnevenRoundedRectangle(
            topLeadingRadius: Self.radius,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: Self.radius,
            style: .continuous
        )
    }

    /// What the tool is, with how it went badged onto the corner: the glyph
    /// says "caption edit" at a glance, the badge says whether it landed.
    private var iconView: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(accentColor.opacity(0.16))
                .frame(width: 24, height: 24)
                .overlay {
                    if status == .pending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    } else {
                        Image(systemName: toolIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(accentColor)
                    }
                }

            if status != .pending {
                Image(systemName: status == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white, accentColor)
                    .offset(x: 3, y: 3)
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailRow: some View {
        if let text = detailText {
            Text(text)
                .font(.caption)
                .foregroundStyle(status == .failed ? Color.red : .secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
    }

    /// The one line of outcome the card shows: the result if there is one,
    /// otherwise what the call is still doing.
    private var detailText: String? {
        if let result = call.result, !result.isEmpty {
            return truncate(collapse(result))
        }
        if status == .pending {
            return call.hasCompleteInput ? "Running…" : "Preparing…"
        }
        return nil
    }

    private var accentColor: Color {
        switch status {
        case .pending: .secondary
        case .ok: .green
        case .failed: .red
        }
    }

    /// A glyph for the family of work the tool does, so a run of cards reads as
    /// a sequence of steps rather than a wall of identical rows.
    private var toolIcon: String {
        let name = MCPToolName.bare(call.name)
        if name.hasPrefix("caption_") { return "captions.bubble" }
        if name.hasPrefix("remotion_") { return "film.stack" }
        if name.hasPrefix("sequence_") { return "rectangle.stack" }
        if name.hasPrefix("podcast_") { return "mic" }
        if name.hasPrefix("music_") { return "music.note" }
        if name.hasPrefix("image_") { return "photo" }
        if name.hasPrefix("video_") { return "video" }
        if name.hasPrefix("narrative_") { return "text.book.closed" }
        if name.contains("project") || name.contains("group") { return "folder" }
        if name.contains("import") || name.contains("footage") { return "tray.and.arrow.down" }
        if name.contains("search") || name.contains("list") { return "magnifyingglass" }
        if name.contains("read") || name.contains("document") { return "doc.text" }
        if name.contains("write") || name.contains("edit") { return "square.and.pencil" }
        return "wrench.and.screwdriver"
    }

    private func truncate(_ s: String) -> String {
        guard s.count > Self.maxDisplayChars else { return s }
        return String(s.prefix(Self.maxDisplayChars)) + "…"
    }

    private func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `{"caption_id":"…","limit":50}` → `caption_id=… limit=50`, so the card
    /// shows what the call actually did without the JSON noise.
    private var compactArgs: String? {
        guard !call.input.isEmpty else { return nil }
        let joined = call.input.keys.sorted().compactMap { key -> String? in
            guard let value = call.input[key] else { return nil }
            return "\(key)=\(Self.plain(value))"
        }
        .joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }

    /// Scalars render bare; anything structured renders as JSON.
    static func plain(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number):
            number == number.rounded() ? String(Int(number)) : String(number)
        case .bool(let flag): String(flag)
        case .null: "null"
        case .object, .array: value.jsonString
        }
    }
}

// MARK: - Tool detail

private struct AgentToolDetailSheet: View {
    let call: AgentToolCall
    @Environment(\.dismiss) private var dismiss

    private var statusLabel: String {
        guard call.isComplete else { return "Running" }
        return call.isError ? "Failed" : "Success"
    }

    private var statusColor: Color {
        guard call.isComplete else { return .secondary }
        return call.isError ? .red : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(MCPToolName.bare(call.name))
                        .font(.headline)
                        .monospaced()
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .glassEffect(.regular.tint(statusColor.opacity(0.18)), in: .capsule)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            section(title: "Parameters", content: prettified(JSONValue.object(call.input)))
            section(
                title: "Result",
                content: call.result.flatMap { prettify($0) } ?? call.result,
                isError: call.isError
            )
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    @ViewBuilder
    private func section(title: String, content: String?, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isError ? .red : .secondary)
            ScrollView {
                Group {
                    if let content, !content.isEmpty {
                        StructuredText(markdown: "```json\n\(content)\n```")
                            .textual.structuredTextStyle(.gitHub)
                            .textual.textSelection(.enabled)
                    } else {
                        Text("—")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .frame(maxHeight: 260)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private func prettified(_ value: JSONValue) -> String? {
        prettify(value.jsonString)
    }

    /// Returns nil when the content isn't JSON, so the caller can fall back to
    /// showing it raw rather than an empty box.
    private func prettify(_ raw: String) -> String? {
        guard !raw.isEmpty,
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(
                  withJSONObject: object,
                  options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}
