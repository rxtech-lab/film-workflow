#if os(macOS)
import Combine
import SwiftData
import SwiftUI

struct RemotionChatView: View {
    @Bindable var project: RemotionProject
    @Binding var reloadToken: Int

    @Environment(\.modelContext) private var modelContext
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var chatTask: Task<Void, Never>?
    @State private var showClearConfirm: Bool = false

    private var orderedMessages: [RemotionMessage] {
        project.messages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        VStack(spacing: 0) {
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

            ScrollViewReader { proxy in
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
                                .id(msg.id)
                        }
                        if isSending {
                            TypingIndicator()
                                .id("typing-indicator")
                                .padding(.horizontal, 4)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: orderedMessages.count) { _, _ in
                    if let last = orderedMessages.last {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: isSending) { _, sending in
                    if sending {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("typing-indicator", anchor: .bottom)
                        }
                    }
                }
            }

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
            }

            Divider()
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask the model to edit the composition…", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSending)
                    .onSubmit { send() }

                if isSending {
                    Button {
                        chatTask?.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop generating")
                    .keyboardShortcut(".", modifiers: [.command])
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "paperplane.fill")
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || project.compositionSource.isEmpty)
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
            ToolCardView(message: msg)
                .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(renderMarkdown(msg.content))
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
    }

    // MARK: - Send

    private func send() {
        let instruction = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty, !isSending else { return }
        guard !project.compositionSource.isEmpty else {
            errorMessage = "Generate the initial composition first."
            return
        }

        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            errorMessage = "Could not load credentials: \(error.localizedDescription)"
            return
        }
        guard !config.openAIEndpoint.isEmpty,
              !config.openAIKey.isEmpty,
              !config.openAIModel.isEmpty else {
            errorMessage = "Set OpenAI endpoint, key, and model in Settings first."
            return
        }

        let userMsg = RemotionMessage(role: RemotionMessageRole.user.rawValue, content: instruction, project: project)
        modelContext.insert(userMsg)
        project.messages.append(userMsg)
        input = ""
        isSending = true
        errorMessage = nil

        let bindable = project
        let history = orderedMessages
        let modelContext = self.modelContext
        chatTask = Task { @MainActor in
            defer {
                isSending = false
                chatTask = nil
            }
            do {
                let stream = RemotionAgent.runEdit(
                    project: bindable,
                    userInstruction: instruction,
                    history: history,
                    config: config
                )

                var anyFileWritten = false
                var pendingToolMessages: [String: RemotionMessage] = [:]
                for try await event in stream {
                    switch event {
                    case .status:
                        // Status updates are ephemeral — surfaced via the typing indicator only.
                        break
                    case .toolCall(let id, let name, let args):
                        let msg = RemotionMessage(
                            role: RemotionMessageRole.assistant.rawValue,
                            content: "",
                            project: bindable,
                            kind: .tool,
                            toolName: name,
                            toolArgs: args,
                            toolStatus: .pending,
                            toolCallId: id
                        )
                        modelContext.insert(msg)
                        bindable.messages.append(msg)
                        pendingToolMessages[id] = msg
                    case .toolResult(let id, _, let summary, let ok):
                        if let msg = pendingToolMessages.removeValue(forKey: id) {
                            msg.toolResult = summary
                            msg.toolStatus = (ok ? RemotionToolStatus.ok : .failed).rawValue
                        }
                    case .assistantText(let text):
                        appendAssistant(text, project: bindable, modelContext: modelContext)
                    case .fileWritten(let path, let content):
                        anyFileWritten = true
                        if path == "src/Composition.tsx" {
                            bindable.compositionSource = content
                        }
                    case .completed:
                        if anyFileWritten {
                            bindable.updatedAt = Date()
                            reloadToken += 1
                        }
                    }
                }
                // Anything still pending at end-of-stream means the loop exited mid-call (rare).
                for msg in pendingToolMessages.values {
                    msg.toolStatus = RemotionToolStatus.failed.rawValue
                    if msg.toolResult == nil { msg.toolResult = "no result" }
                }
            } catch is CancellationError {
                // user-initiated, no error UI
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func appendAssistant(_ content: String, project: RemotionProject, modelContext: ModelContext) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = RemotionMessage(
            role: RemotionMessageRole.assistant.rawValue,
            content: trimmed,
            project: project
        )
        modelContext.insert(msg)
        project.messages.append(msg)
    }

    private func clearAllMessages() {
        let messages = project.messages
        project.messages.removeAll()
        for msg in messages {
            modelContext.delete(msg)
        }
        errorMessage = nil
    }

    private func renderMarkdown(_ source: String) -> AttributedString {
        if let parsed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return parsed
        }
        return AttributedString(source)
    }
}

private struct ToolCardView: View {
    let message: RemotionMessage

    private var status: RemotionToolStatus {
        guard let raw = message.toolStatus,
              let s = RemotionToolStatus(rawValue: raw) else {
            return .pending
        }
        return s
    }

    var body: some View {
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
                        Text(args)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if let result = message.toolResult, !result.isEmpty {
                    Text(result)
                        .font(.caption)
                        .foregroundStyle(status == .failed ? .red : .secondary)
                        .lineLimit(3)
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
