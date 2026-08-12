import SwiftUI
import Textual

/// One transcript row: plain text, a tool card, or a caption-edit proposal.
///
/// The tool card and its detail sheet are carried over from the Remotion chat
/// view — that design was the better of the two the app had, and it now serves
/// every backend rather than only the OpenAI loop.
struct AgentMessageRow: View {
    let message: AgentMessage
    /// Opens the review sheet for this row. Handed the row itself rather than
    /// its proposal, because applying writes the outcome back onto it.
    var onReviewProposal: (AgentMessage) -> Void = { _ in }

    var body: some View {
        Group {
            switch message.kindEnum {
            case .tool:
                HStack(spacing: 0) {
                    AgentToolCard(message: message)
                        .frame(maxWidth: 460, alignment: .leading)
                    Spacer(minLength: 0)
                }
            case .proposal:
                proposalCard
            case .text:
                if message.roleEnum == .system {
                    // Something the app did on the user's behalf — applying a
                    // reviewed batch — not something either party said. It is
                    // still replayed to the model, so the agent knows how the
                    // review went before it answers again.
                    Label(message.content, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                } else if message.roleEnum == .user {
                    HStack {
                        Spacer(minLength: 40)
                        Text(message.content)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.accentColor.opacity(0.18))
                            )
                    }
                } else {
                    StructuredText(markdown: message.content)
                        .textual.structuredTextStyle(.gitHub)
                        .textual.textSelection(.enabled)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                }
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Proposal

    private var proposalCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(message.content.isEmpty ? "Proposed changes" : message.content)
            } icon: {
                Image(systemName: "checklist")
            }
            .font(.callout)

            if let proposal = message.proposal {
                // Reviewed once already: say what came of it, and let the user
                // go back in — the rest of the batch may still be waiting.
                if let applied = message.proposalAppliedCount {
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
                    message.proposalAppliedCount == nil
                        ? "Review \(proposal.items.count) change\(proposal.items.count == 1 ? "" : "s")…"
                        : "Review again…"
                ) {
                    onReviewProposal(message)
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
    let message: AgentMessage
    @State private var showDetails = false
    @State private var isHovered = false

    private static let maxDisplayChars = 200

    private var status: AgentToolStatus { message.toolStatusEnum ?? .pending }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(spacing: 0) {
                // Colored left accent strip
                RoundedRectangle(cornerRadius: 2)
                    .fill(accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 6)

                HStack(alignment: .center, spacing: 10) {
                    iconView

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(message.toolName ?? "tool")
                                .font(.caption.weight(.semibold))
                                .monospaced()
                                .foregroundStyle(.primary)
                            if let args = compactArgs(message.toolArgs), !args.isEmpty {
                                Text(truncate(args))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        resultLine
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHovered ? accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(accentColor.opacity(0.25), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .sheet(isPresented: $showDetails) {
            AgentToolDetailSheet(message: message)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        ZStack {
            Circle()
                .fill(accentColor.opacity(0.12))
                .frame(width: 26, height: 26)
            switch status {
            case .pending:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
            case .ok:
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accentColor)
            case .failed:
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(accentColor)
            }
        }
    }

    @ViewBuilder
    private var resultLine: some View {
        if let result = message.toolResult, !result.isEmpty {
            Text(truncate(result))
                .font(.caption)
                .foregroundStyle(status == .failed ? .red : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        } else if status == .pending {
            Text("Running…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var accentColor: Color {
        switch status {
        case .pending: return .secondary
        case .ok:     return .green
        case .failed: return .red
        }
    }

    private func truncate(_ s: String) -> String {
        guard s.count > Self.maxDisplayChars else { return s }
        return String(s.prefix(Self.maxDisplayChars)) + "…"
    }

    /// `{"caption_id":"…","limit":50}` → `caption_id=… limit=50`, so the card
    /// shows what the call actually did without the JSON noise.
    private func compactArgs(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let joined = dict.keys.sorted().compactMap { key -> String? in
                guard let value = dict[key] else { return nil }
                return "\(key)=\(value)"
            }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return raw
    }
}

// MARK: - Tool detail

private struct AgentToolDetailSheet: View {
    let message: AgentMessage
    @Environment(\.dismiss) private var dismiss

    private var status: AgentToolStatus { message.toolStatusEnum ?? .pending }

    private var statusLabel: String {
        switch status {
        case .pending: return "Running"
        case .ok:      return "Success"
        case .failed:  return "Failed"
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending: return .secondary
        case .ok:      return .green
        case .failed:  return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.toolName ?? "tool")
                        .font(.headline)
                        .monospaced()
                    Text(statusLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(statusColor.opacity(0.12))
                        )
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            section(title: "Parameters", content: prettifyJSON(message.toolArgs))
            section(
                title: "Result",
                content: prettifyJSON(message.toolResult) ?? message.toolResult,
                isError: message.toolStatusEnum == .failed
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

    /// Returns nil when the content isn't JSON, so the caller can fall back to
    /// showing it raw rather than an empty box.
    private func prettifyJSON(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
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
