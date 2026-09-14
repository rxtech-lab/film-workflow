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
            // The SDK folded these blind to what they are; a proposal inside
            // the run still has to surface as its review card.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(segments(of: calls.map { .toolCall($0) })) { segment in
                    switch segment {
                    case .block(let block):
                        if case .toolCall(let call) = block { toolRow(call) }
                    case .toolRun(let run):
                        toolGroup(run)
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
            if !message.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(message.attachments) { attachment in
                            AgentAttachmentPreview(attachment: attachment)
                        }
                    }
                }
                .defaultScrollAnchor(message.role == .user ? .trailing : .leading)
            }
            ForEach(segments(of: message.blocks)) { segment in
                switch segment {
                case .block(let block):
                    switch block {
                    case .text(_, let text):
                        textBlock(text, role: message.role)
                    case .thinking(_, let text):
                        thinkingBlock(text)
                    case .toolCall(let call):
                        toolRow(call)
                    }
                case .toolRun(let calls):
                    toolGroup(calls)
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

    // MARK: - Segments

    /// A message's blocks with consecutive tool calls folded into one run, so
    /// a burst of lookups collapses into a single chip instead of a column of
    /// them. A proposal breaks the run: it is something waiting on the user,
    /// and must not hide inside a collapsed group.
    private enum Segment: Identifiable {
        case block(AgentBlock)
        case toolRun([AgentToolCall])

        var id: String {
            switch self {
            case .block(let block): block.id
            case .toolRun(let calls): "run-\(calls.first?.id ?? "")"
            }
        }
    }

    private func segments(of blocks: [AgentBlock]) -> [Segment] {
        var segments: [Segment] = []
        var run: [AgentToolCall] = []
        func flush() {
            guard !run.isEmpty else { return }
            segments.append(.toolRun(run))
            run = []
        }
        for block in blocks {
            if case .toolCall(let call) = block,
               proposalRow(for: call) == nil,
               marketplaceCard(for: call) == nil,
               WizardStepCard.summary(for: call) == nil {
                run.append(call)
            } else {
                flush()
                segments.append(.block(block))
            }
        }
        flush()
        return segments
    }

    /// One call stands on its own; two or more fold into a group chip that
    /// opens onto the individual chips.
    @ViewBuilder
    private func toolGroup(_ calls: [AgentToolCall]) -> some View {
        if calls.count == 1, let call = calls.first {
            toolRow(call)
        } else {
            HStack(spacing: 0) {
                // One container for the run of chips, so their glass blends
                // into each other instead of each sampling on its own.
                GlassEffectContainer(spacing: 6) {
                    AgentToolGroupCard(calls: calls)
                }
                .frame(maxWidth: 460, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Tool

    @ViewBuilder
    private func toolRow(_ call: AgentToolCall) -> some View {
        if let payload = marketplaceCard(for: call) {
            MarketplaceChatCard(payload: payload, showPublishButton: payload.showPublishButton ?? true)
        } else if let summary = WizardStepCard.summary(for: call) {
            WizardStepCard(summary: summary)
        } else if let row = proposalRow(for: call) {
            proposalCard(row)
        } else {
            HStack(spacing: 0) {
                AgentToolCard(call: call)
                    .frame(maxWidth: 460, alignment: .leading)
                Spacer(minLength: 0)
            }
        }
    }

    /// Item data from reads and writes stays in the normal tool result. Only
    /// the explicit presentation tool can surface a marketplace card, including
    /// when replaying older transcripts or receiving namespaced CLI tool names.
    private func marketplaceCard(for call: AgentToolCall) -> MarketplaceCardPayload? {
        guard MCPToolName.bare(call.name) == "show_marketplace_item",
              call.isComplete, !call.isError else { return nil }
        return MarketplaceCardPayload.decode(call.result)
    }

    /// The persisted proposal row this call produced, if it produced one.
    ///
    /// Matched by item rather than by call id: a proposal arriving from a CLI
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

// MARK: - Tool status

/// How a call (or a run of them) went, and the colour that says so.
private enum ToolStatus {
    case pending, ok, failed

    init(_ call: AgentToolCall) {
        guard call.isComplete else { self = .pending; return }
        self = call.isError ? .failed : .ok
    }

    /// Pending if anything is still running, failed if anything failed,
    /// otherwise ok — the group is only as done as its slowest member.
    init(_ calls: [AgentToolCall]) {
        if calls.contains(where: { !$0.isComplete }) { self = .pending }
        else if calls.contains(where: \.isError) { self = .failed }
        else { self = .ok }
    }

    var accent: Color {
        switch self {
        case .pending: .secondary
        case .ok: .green
        case .failed: .red
        }
    }
}

/// A glyph for the family of work the tool does, so a run of chips reads as
/// a sequence of steps rather than a wall of identical rows.
private func toolGlyph(for toolName: String) -> String {
    let name = MCPToolName.bare(toolName)
    if name.hasPrefix("caption_") { return "captions.bubble" }
    if name.hasPrefix("remotion_") { return "film.stack" }
    if name.hasPrefix("sequence_") { return "rectangle.stack" }
    if name.hasPrefix("podcast_") { return "mic" }
    if name.hasPrefix("music_") { return "music.note" }
    if name.hasPrefix("image_") { return "photo" }
    if name.hasPrefix("video_") { return "video" }
    if name.hasPrefix("narration_") { return "text.book.closed" }
    if name.hasPrefix("folder_") { return "folder" }
    if name.hasPrefix("film_") { return "film" }
    if name.hasPrefix("footage_import") { return "tray.and.arrow.down" }
    if name.hasPrefix("footage_") { return "square.grid.2x2" }
    if name.contains("search") || name.contains("list") { return "magnifyingglass" }
    if name.contains("read") || name.contains("document") { return "doc.text" }
    if name.contains("write") || name.contains("edit") { return "square.and.pencil" }
    return "wrench.and.screwdriver"
}

/// What the work is, with how it went badged onto the corner: the glyph says
/// "caption edit" at a glance, the badge says whether it landed.
private struct ToolStatusIcon: View {
    let glyph: String
    let status: ToolStatus

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(status.accent.opacity(0.16))
                .frame(width: 24, height: 24)
                .overlay {
                    if status == .pending {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.65)
                    } else {
                        Image(systemName: glyph)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(status.accent)
                    }
                }

            if status != .pending {
                Image(systemName: status == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white, status.accent)
                    .offset(x: 3, y: 3)
            }
        }
    }
}

/// The chip's glass shape: fully rounded on its own, open along the bottom
/// when a body hangs beneath it.
private func chipShape(open: Bool, radius: CGFloat) -> UnevenRoundedRectangle {
    let bottom: CGFloat = open ? 0 : radius
    return UnevenRoundedRectangle(
        topLeadingRadius: radius,
        bottomLeadingRadius: bottom,
        bottomTrailingRadius: bottom,
        topTrailingRadius: radius,
        style: .continuous
    )
}

// MARK: - Tool group card

/// A run of consecutive tool calls folded into one chip. Collapsed, it says
/// how many steps there were and how they are going; expanded, it lists each
/// call as its own chip, which opens further on its own.
private struct AgentToolGroupCard: View {
    let calls: [AgentToolCall]
    @State private var isExpanded = false
    @State private var isHovered = false

    private static let radius: CGFloat = 12

    private var status: ToolStatus { ToolStatus(calls) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(calls) { call in
                        AgentToolCard(call: call)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .background {
            if isExpanded {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(status.accent.opacity(0.16), lineWidth: 0.5)
                    )
            }
        }
        .animation(.snappy(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: status)
    }

    private var header: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                ToolStatusIcon(glyph: "square.stack.3d.up", status: status)

                Text("\(calls.count) tool calls")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)

                if let hint {
                    Text(hint)
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(status == .failed ? Color.red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if isExpanded {
                    Spacer(minLength: 4)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .glassEffect(
            .regular.tint(status.accent.opacity(isHovered ? 0.24 : 0.11)).interactive(),
            in: chipShape(open: isExpanded, radius: Self.radius)
        )
    }

    /// While running, the step in flight; once done, either what failed or
    /// the distinct tools that ran, so the collapsed chip still says what the
    /// agent did without opening it.
    private var hint: String? {
        switch status {
        case .pending:
            guard let active = calls.first(where: { !$0.isComplete }) else { return nil }
            return "Running \(MCPToolName.bare(active.name))…"
        case .failed:
            let failed = calls.filter(\.isError).count
            return "\(failed) failed"
        case .ok:
            var seen = Set<String>()
            let names = calls.map { MCPToolName.bare($0.name) }.filter { seen.insert($0).inserted }
            return names.joined(separator: ", ")
        }
    }
}

// MARK: - Tool card

/// A tool call as a chip: the glyph, the name, and how it went. Nothing else
/// until the user asks — expanding the chip reveals the parameters and a
/// preview of the result inline, and from there the full detail sheet.
private struct AgentToolCard: View {
    let call: AgentToolCall
    @State private var isExpanded = false
    @State private var showDetails = false
    @State private var isHovered = false

    private static let radius: CGFloat = 12
    private static let maxPreviewChars = 600
    private static let maxValueChars = 160

    private var status: ToolStatus { ToolStatus(call) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            chip
            if isExpanded {
                expandedBody
                    .transition(.opacity)
            }
        }
        .background {
            // Only drawn once the body is open — collapsed, the glass edge is
            // the chip's edge, and a second outline would double it.
            if isExpanded {
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(Color.secondary.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(status.accent.opacity(0.16), lineWidth: 0.5)
                    )
            }
        }
        .animation(.snappy(duration: 0.18), value: isExpanded)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: status)
        .sheet(isPresented: $showDetails) {
            AgentToolDetailSheet(call: call)
        }
    }

    // MARK: - Chip

    /// The tool name on liquid glass tinted by the call's outcome. Collapsed
    /// it hugs its content like a chip; expanded it stretches into the header
    /// of the card, and its bottom corners open onto the body underneath.
    private var chip: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                ToolStatusIcon(glyph: toolGlyph(for: call.name), status: status)

                Text(MCPToolName.bare(call.name))
                    .font(.caption.weight(.semibold))
                    .monospaced()
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if let hint = statusHint {
                    Text(hint)
                        .font(.caption2)
                        .foregroundStyle(status == .failed ? Color.red : .secondary)
                        .lineLimit(1)
                }

                if isExpanded {
                    Spacer(minLength: 4)
                }

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .glassEffect(
            .regular.tint(status.accent.opacity(isHovered ? 0.24 : 0.11)).interactive(),
            in: chipShape(open: isExpanded, radius: Self.radius)
        )
    }

    /// One word on how the call is going, shown only while there is something
    /// to say: a finished call already carries its outcome in the icon badge.
    private var statusHint: String? {
        switch status {
        case .pending: call.hasCompleteInput ? "Running…" : "Preparing…"
        case .failed: "Failed"
        case .ok: nil
        }
    }

    // MARK: - Expanded body

    private var expandedBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            section("Parameters") {
                if sortedInput.isEmpty {
                    Text(call.hasCompleteInput ? "None" : "Preparing…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    parameterList
                }
            }

            if let result = call.result, !result.isEmpty {
                section("Result", isError: call.isError) {
                    Text(truncate(result.trimmingCharacters(in: .whitespacesAndNewlines), to: Self.maxPreviewChars))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(status == .failed ? Color.red : .primary)
                        .lineLimit(8)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button("Show full details…") {
                showDetails = true
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(
        _ title: String,
        isError: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isError ? Color.red : .secondary)
            content()
        }
    }

    private var sortedInput: [(key: String, value: JSONValue)] {
        call.input.sorted { $0.key < $1.key }
    }

    /// `{"footage_id":"…","limit":50}` → two rows, `footage_id` / `…` and
    /// `limit` / `50`, so the parameters read as a table rather than JSON.
    private var parameterList: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 3) {
            ForEach(sortedInput, id: \.key) { entry in
                GridRow {
                    Text(entry.key)
                        .font(.caption2.weight(.medium))
                        .monospaced()
                        .foregroundStyle(.secondary)
                    Text(truncate(collapse(Self.plain(entry.value)), to: Self.maxValueChars))
                        .font(.caption2)
                        .monospaced()
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - Helpers

    private func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    private func collapse(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
