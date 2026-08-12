import SwiftUI
import Textual

/// One transcript row: plain text, a tool card, or a caption-edit proposal.
///
/// The tool card and its detail sheet are carried over from the Remotion chat
/// view — that design was the better of the two the app had, and it now serves
/// every backend rather than only the OpenAI loop.
struct AgentMessageRow: View {
    let message: AgentMessage
    /// Opens the review sheet for a proposal row.
    var onReviewProposal: (CaptionEditProposal) -> Void = { _ in }

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
                if message.roleEnum == .user {
                    HStack {
                        Spacer(minLength: 40)
                        Text(message.content)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
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
                Button("Review \(proposal.items.count) change\(proposal.items.count == 1 ? "" : "s")…") {
                    onReviewProposal(proposal)
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

    private static let maxDisplayChars = 200

    private var status: AgentToolStatus { message.toolStatusEnum ?? .pending }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                icon
                    .frame(width: 16, height: 16)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(message.toolName ?? "tool")
                            .font(.caption.weight(.semibold))
                            .monospaced()
                        if let args = compactArgs(message.toolArgs), !args.isEmpty {
                            Text(truncate(args))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
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

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(borderColor.opacity(0.5), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showDetails) {
            AgentToolDetailSheet(message: message)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch status {
        case .pending:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .ok:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var borderColor: Color {
        switch status {
        case .pending: return .secondary
        case .ok: return .green
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
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(message.toolName ?? "tool")
                    .font(.headline)
                    .monospaced()
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

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
