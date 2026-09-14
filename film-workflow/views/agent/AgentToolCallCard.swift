import RxAgentSDK
import SwiftUI
import Textual

// MARK: - Summary

/// What a tool call says when it appears in the transcript.
///
/// The transcript is a conversation, not a log. A call gets one line — what it
/// did, to what, and how it went — so only the argument that names the subject
/// (the file being written, the caption being edited) is printed. The rest are
/// counted, and wait in the detail sheet behind the row: a chat list is no
/// place for a JSON dump.
struct AgentToolSummary {
    /// The tool name with any `mcp__server__` prefix stripped.
    let name: String
    /// `caption_update_segment` → "Update caption segment".
    let title: String
    let icon: String
    /// The one argument worth naming, already shortened for a single line.
    let subject: String?
    /// How many arguments the row is not showing, so it can say so.
    let hiddenCount: Int

    init(call: AgentToolCall) {
        let bare = MCPToolName.bare(call.name)
        name = bare
        title = Self.title(for: bare)
        icon = Self.icon(for: bare)

        let found = Self.subject(in: call.input)
        subject = found?.text
        hiddenCount = max(0, call.input.count - (found == nil ? 0 : 1))
    }

    // MARK: Title

    /// Verbs that read better at the front of the label, wherever the tool name
    /// happens to put them: `caption_update_segment` and `update_project` are
    /// the same shape of action and should read alike.
    private static let verbs: Set<String> = [
        "add", "apply", "close", "create", "delete", "duplicate", "edit",
        "export", "fetch", "generate", "get", "import", "list", "move", "open",
        "propose", "read", "remove", "render", "rename", "resume", "run",
        "search", "send", "set", "take", "transcribe", "translate", "update",
        "write",
    ]

    /// Snake-cased tool names become a sentence; anything else — `Read`,
    /// `Bash`, a tool from some other server — is left exactly as it came.
    static func title(for name: String) -> String {
        var parts = name.split(separator: "_").map(String.init)
        guard parts.count > 1 else { return name }

        if let verbIndex = parts.firstIndex(where: { verbs.contains($0.lowercased()) }) {
            let verb = parts.remove(at: verbIndex)
            parts.insert(verb, at: 0)
        }
        let sentence = parts.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    // MARK: Subject

    /// Argument names that say *what* a call is acting on, most telling first.
    /// Ids are deliberately absent — `caption_id=8F2C…` names nothing a reader
    /// recognises, and the card would rather stay quiet than print a UUID.
    private static let subjectKeys = [
        "path", "file_path", "relative_path", "filename", "title", "name",
        "label", "query", "prompt", "text", "command", "url", "format",
        "language", "target_language", "index",
    ]

    private static func subject(in input: [String: JSONValue]) -> (key: String, text: String)? {
        for key in subjectKeys {
            guard let value = input[key], let text = display(key: key, value: value) else { continue }
            return (key, text)
        }
        return nil
    }

    /// Strings speak for themselves; a bare number doesn't, so it keeps its
    /// key ("index 12"). Structured values are never a subject — they are what
    /// the detail sheet is for.
    private static func display(key: String, value: JSONValue) -> String? {
        switch value {
        case .string(let raw):
            let text = collapse(raw)
            guard !text.isEmpty else { return nil }
            return truncate(key.hasSuffix("path") ? (text as NSString).lastPathComponent : text)
        case .number, .bool:
            return "\(key.replacingOccurrences(of: "_", with: " ")) \(scalarText(value))"
        case .object, .array, .null:
            return nil
        }
    }

    /// A scalar as a reader would write it; structured values fall back to JSON.
    static func scalarText(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text
        case .number(let number):
            number.isFinite && number == number.rounded()
                ? String(format: "%.0f", number)
                : String(number)
        case .bool(let flag): String(flag)
        case .null: "null"
        case .object, .array: value.jsonString
        }
    }

    // MARK: Icon

    /// A glyph for the family of work the tool does, so a run of calls reads as
    /// a sequence of steps rather than a stack of identical rows.
    static func icon(for name: String) -> String {
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

    /// The family's colour, carried by the glyph alone. The row's own tint
    /// stays neutral, so a long run of calls doesn't turn into a rainbow.
    var accent: Color {
        if name.hasPrefix("caption_") { return .teal }
        if name.hasPrefix("remotion_") { return .purple }
        if name.hasPrefix("sequence_") { return .indigo }
        if name.hasPrefix("podcast_") { return .pink }
        if name.hasPrefix("music_") { return .orange }
        if name.hasPrefix("image_") { return .blue }
        if name.hasPrefix("video_") { return .cyan }
        if name.hasPrefix("narrative_") { return .brown }
        return .secondary
    }

    // MARK: Text helpers

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func truncate(_ text: String, limit: Int = 56) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - Card

/// One tool call in the transcript: a single quiet line that opens its full
/// arguments and result in a sheet.
///
/// Success is the ordinary case, so it is drawn as quietly as possible — the
/// row earns colour only while it is running or when it failed.
struct AgentToolCallCard: View {
    let call: AgentToolCall
    private let summary: AgentToolSummary

    @State private var showDetails = false
    @State private var isHovered = false

    private enum Status { case pending, ok, failed }

    init(call: AgentToolCall) {
        self.call = call
        self.summary = AgentToolSummary(call: call)
    }

    /// Where the title starts, so the result line underneath lands on the same
    /// left edge instead of floating under the glyph.
    private static let titleInset: CGFloat = 31

    private var status: Status {
        guard call.isComplete else { return .pending }
        return call.isError ? .failed : .ok
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                headline
                resultLine
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show parameters and result")
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.2), value: call.isComplete)
        .sheet(isPresented: $showDetails) {
            AgentToolDetailSheet(call: call)
        }
    }

    // MARK: Headline

    private var headline: some View {
        HStack(spacing: 7) {
            glyph

            Text(summary.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)

            if let subject = summary.subject {
                Text(subject)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if summary.hiddenCount > 0 {
                // Says how much the row is holding back, so the chevron reads
                // as a way in rather than as decoration.
                Text("+\(summary.hiddenCount)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .opacity(isHovered ? 1 : 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .glassEffect(
            .regular.tint(tint).interactive(),
            in: .rect(cornerRadius: 9, style: .continuous)
        )
    }

    private var glyph: some View {
        Group {
            if status == .pending {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
            } else {
                Image(systemName: summary.icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(status == .failed ? Color.red : summary.accent)
            }
        }
        .frame(width: 15, height: 15)
    }

    /// Neutral once it lands — a transcript of twenty successful calls should
    /// read as twenty quiet lines, with only a failure pulling the eye.
    private var tint: Color {
        switch status {
        case .pending: Color.accentColor.opacity(isHovered ? 0.22 : 0.14)
        case .ok: Color.secondary.opacity(isHovered ? 0.18 : 0.08)
        case .failed: Color.red.opacity(isHovered ? 0.22 : 0.13)
        }
    }

    // MARK: Result

    /// One line of outcome, indented under the label. Nothing is drawn while
    /// the call is in flight — the spinner already says that.
    @ViewBuilder
    private var resultLine: some View {
        if let result = call.result, !result.isEmpty {
            Text(AgentToolSummary.truncate(AgentToolSummary.collapse(result), limit: 140))
                .font(.caption2)
                .foregroundStyle(status == .failed ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, Self.titleInset)
        }
    }
}

// MARK: - Detail sheet

/// Everything the card left out: every argument, and the whole result.
struct AgentToolDetailSheet: View {
    let call: AgentToolCall
    private let summary: AgentToolSummary

    @Environment(\.dismiss) private var dismiss

    init(call: AgentToolCall) {
        self.call = call
        self.summary = AgentToolSummary(call: call)
    }

    private var statusLabel: String {
        guard call.isComplete else { return "Running" }
        return call.isError ? "Failed" : "Success"
    }

    private var statusColor: Color {
        guard call.isComplete else { return .secondary }
        return call.isError ? .red : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    parameters
                    resultSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 380)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: summary.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(summary.accent)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(summary.accent.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .font(.headline)
                // The name the model actually called, which the transcript no
                // longer shows — and which is what a bug report needs.
                Text(summary.name)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text(statusLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .glassEffect(.regular.tint(statusColor.opacity(0.18)), in: .capsule)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Parameters

    private var parameters: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Parameters")
            if call.input.isEmpty {
                emptyLine(call.hasCompleteInput ? "No parameters." : "Still streaming…")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(call.input.keys.sorted().enumerated()), id: \.element) { index, key in
                        if index > 0 { Divider() }
                        parameterRow(key: key, value: call.input[key] ?? .null)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.secondary.opacity(0.07))
                )
            }
        }
    }

    @ViewBuilder
    private func parameterRow(key: String, value: JSONValue) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(.caption)
                .monospaced()
                .foregroundStyle(.secondary)
                .frame(width: 140, alignment: .trailing)

            switch value {
            case .object, .array:
                // Structured arguments stay JSON; there is no flatter way to
                // read a nested edit list.
                code(prettify(value.jsonString) ?? value.jsonString)
            default:
                Text(AgentToolSummary.scalarText(value))
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: Result

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Result", isError: call.isError)
            if let result = call.result, !result.isEmpty {
                code(prettify(result) ?? result)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.07))
                    )
            } else {
                emptyLine(call.isComplete ? "No result." : "Waiting for the tool to return…")
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
    }

    private func emptyLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    private func code(_ text: String) -> some View {
        StructuredText(markdown: "```json\n\(text)\n```")
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Preview

#Preview("Tool calls") {
    GlassEffectContainer(spacing: 6) {
        VStack(alignment: .leading, spacing: 5) {
            AgentToolCallCard(call: AgentToolCall(
                id: "1",
                name: "mcp__film_workflow__caption_transcribe",
                input: ["caption_id": .string("8F2C-AAAA"), "model": .string("whisper-large")],
                hasCompleteInput: true
            ))
            AgentToolCallCard(call: AgentToolCall(
                id: "2",
                name: "mcp__film_workflow__caption_update_segment",
                input: [
                    "caption_id": .string("8F2C-AAAA"),
                    "index": .number(12),
                    "text": .string("And that is how the harbour froze over."),
                    "speaker": .string("Narrator"),
                ],
                result: "Updated caption 12.",
                hasCompleteInput: true
            ))
            AgentToolCallCard(call: AgentToolCall(
                id: "3",
                name: "mcp__film_workflow__remotion_write_file",
                input: [
                    "project_id": .string("R-1"),
                    "path": .string("src/Title.tsx"),
                    "content": .string("export const Title = () => …"),
                ],
                result: "Wrote 1.2 KB to src/Title.tsx.",
                hasCompleteInput: true
            ))
            AgentToolCallCard(call: AgentToolCall(
                id: "4",
                name: "mcp__film_workflow__list_projects",
                result: "3 projects: Harbour, Trailer, Test.",
                hasCompleteInput: true
            ))
            AgentToolCallCard(call: AgentToolCall(
                id: "5",
                name: "mcp__film_workflow__sequence_render",
                input: ["sequence_id": .string("S-9"), "format": .string("mp4")],
                result: "No renderable clips on the timeline.",
                isError: true,
                hasCompleteInput: true
            ))
        }
        .frame(maxWidth: 460, alignment: .leading)
    }
    .padding(20)
    .frame(width: 520)
}
