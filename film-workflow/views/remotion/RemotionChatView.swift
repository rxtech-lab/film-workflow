#if os(macOS)
import Combine
import SwiftData
import SwiftUI
import Textual

struct RemotionChatView: View {
    @Bindable var project: RemotionProject
    @Binding var reloadToken: Int

    @Environment(\.modelContext) private var modelContext
    @Environment(RemotionChatController.self) private var controller
    @State private var showClearConfirm: Bool = false

    private var orderedMessages: [RemotionMessage] {
        project.messages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        let session = controller.session(for: project.id)
        let isSending = session.isSending
        let inputBinding = Binding<String>(
            get: { controller.session(for: project.id).input },
            set: { controller.setInput($0, for: project.id) }
        )

        return VStack(spacing: 0) {
            HStack {
                Text("Chat — refine the composition")
                    .font(.subheadline.bold())
                Spacer()
                Button {
                    showClearConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Clear all messages")
                .disabled(orderedMessages.isEmpty || isSending)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if orderedMessages.isEmpty {
                        Text("Describe a change — e.g. \"make the title yellow\" or \"slow the fade to 1s\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(orderedMessages) { msg in
                        messageRow(msg)
                            .id(ChatScrollAnchor.message(msg.id))
                    }
                    if isSending {
                        TypingIndicator()
                            .id(ChatScrollAnchor.typing)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 108)
                .padding(.horizontal, 16)
                .scrollTargetLayout()
            }
            .defaultScrollAnchor(.bottom)
            .scrollPosition(id: Binding<ChatScrollAnchor?>(
                get: { controller.session(for: project.id).scrollAnchor },
                set: { controller.setScrollAnchor($0, for: project.id) }
            ), anchor: .bottom)
            .onChange(of: orderedMessages.count) { _, _ in
                if let last = orderedMessages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        controller.setScrollAnchor(.message(last.id), for: project.id)
                    }
                }
            }
            .onChange(of: isSending) { _, sending in
                if sending {
                    withAnimation(.easeOut(duration: 0.15)) {
                        controller.setScrollAnchor(.typing, for: project.id)
                    }
                }
            }

            if let err = session.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()
            HStack(alignment: .center, spacing: 8) {
                TextField("Ask the model to edit the composition…", text: inputBinding, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSending)
                    .onSubmit { send() }

                if isSending {
                    Button {
                        controller.cancel(projectId: project.id)
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(.regular.tint(.red).interactive(), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Stop generating")
                    .keyboardShortcut(".", modifiers: [.command])
                } else {
                    let isDisabled = session.input.trimmingCharacters(in: .whitespaces).isEmpty || project.compositionSource.isEmpty
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .glassEffect(
                                .regular.tint(isDisabled ? .gray : .accentColor).interactive(),
                                in: .circle
                            )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(isDisabled)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            "Clear all chat messages?",
            isPresented: $showClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All", role: .destructive) { clearAllMessages() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes all messages in this chat. The composition itself is not affected.")
        }
    }

    @ViewBuilder
    private func messageRow(_ msg: RemotionMessage) -> some View {
        if msg.kind == RemotionMessageKind.tool.rawValue {
            HStack(spacing: 0) {
                ToolCardView(message: msg)
                    .frame(maxWidth: 400, alignment: .leading)
                Spacer(minLength: 0)
            }
        } else if msg.role == RemotionMessageRole.user.rawValue {
            HStack {
                Spacer(minLength: 40)
                Text(msg.content)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.accentColor.opacity(0.18))
                    )
            }
        } else {
            StructuredText(markdown: msg.content)
                .textual.structuredTextStyle(.gitHub)
                .textual.textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Send

    private func send() {
        let session = controller.session(for: project.id)
        let instruction = session.input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !session.isSending else { return }
        guard !project.compositionSource.isEmpty else {
            controller.setError("Generate the initial composition first.", for: project.id)
            return
        }

        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            controller.setError("Could not load credentials: \(error.localizedDescription)", for: project.id)
            return
        }
        guard !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty,
              !config.openAIModel.isEmpty else {
            controller.setError("Set OpenAI endpoint, key, and model in Settings first.", for: project.id)
            return
        }

        controller.send(
            instruction: instruction,
            project: project,
            history: orderedMessages,
            config: config,
            modelContext: modelContext,
            onCompleted: { anyFileWritten in
                if anyFileWritten { reloadToken += 1 }
            }
        )
    }

    private func clearAllMessages() {
        let messages = project.messages
        project.messages.removeAll()
        for msg in messages {
            modelContext.delete(msg)
        }
        controller.setError(nil, for: project.id)
    }

}


private struct ToolCardView: View {
    let message: RemotionMessage
    @State private var showDetails: Bool = false

    private static let maxDisplayChars: Int = 200

    private var status: RemotionToolStatus {
        guard let raw = message.toolStatus,
              let s = RemotionToolStatus(rawValue: raw) else {
            return .pending
        }
        return s
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(alignment: .top, spacing: 8) {
                iconView
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
            ToolCallDetailSheet(message: message)
        }
    }

    private func truncate(_ s: String) -> String {
        guard s.count > Self.maxDisplayChars else { return s }
        return String(s.prefix(Self.maxDisplayChars)) + "…"
    }

    @ViewBuilder
    private var iconView: some View {
        switch status {
        case .pending:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var borderColor: Color {
        switch status {
        case .pending: return .secondary
        case .ok: return .green
        case .failed: return .red
        }
    }

    private func compactArgs(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // Try to compact JSON to a single line; if it fails, return raw.
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any] {
            let joined = dict.keys.sorted().compactMap { key -> String? in
                guard let v = dict[key] else { return nil }
                let s = "\(v)"
                return "\(key)=\(s)"
            }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return raw
    }
}

private struct ToolCallDetailSheet: View {
    let message: RemotionMessage
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

            section(
                title: "Parameters",
                content: prettifyJSON(message.toolArgs),
                language: "json"
            )
            section(
                title: "Result",
                content: prettifyResult(message.toolResult),
                language: resultLanguage(message.toolResult),
                isError: (message.toolStatus == RemotionToolStatus.failed.rawValue)
            )
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    @ViewBuilder
    private func section(
        title: String,
        content: String?,
        language: String,
        isError: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Group {
                    if let content, !content.isEmpty {
                        StructuredText(markdown: "```\(language)\n\(content)\n```")
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
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(
                        (isError ? Color.red : Color.clear).opacity(0.5),
                        lineWidth: 0.5
                    )
            )
        }
    }

    private func prettifyJSON(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: obj,
               options: [.prettyPrinted, .sortedKeys]
           ),
           let s = String(data: pretty, encoding: .utf8) {
            return s
        }
        return raw
    }

    private func prettifyResult(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        // If the result happens to be JSON (most tool results are), pretty-print it.
        if let pretty = prettifyJSON(raw), pretty != raw { return pretty }
        return raw
    }

    private func resultLanguage(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return "json" }
        return ""
    }
}

private struct TypingIndicator: View {
    @State private var phase: Int = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1.0 : 0.3)
                    .animation(.easeInOut(duration: 0.3), value: phase)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
#endif
