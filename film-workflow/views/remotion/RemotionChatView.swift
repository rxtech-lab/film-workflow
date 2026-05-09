#if os(macOS)
import SwiftData
import SwiftUI

struct RemotionChatView: View {
    @Bindable var project: RemotionProject
    @Binding var reloadToken: Int

    @Environment(\.modelContext) private var modelContext
    @State private var input: String = ""
    @State private var isSending: Bool = false
    @State private var errorMessage: String?

    private var orderedMessages: [RemotionMessage] {
        project.messages.sorted(by: { $0.createdAt < $1.createdAt })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Chat — refine the composition")
                    .font(.subheadline.bold())
                Spacer()
                if isSending {
                    ProgressView().controlSize(.small)
                }
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

                Button {
                    send()
                } label: {
                    Image(systemName: "paperplane.fill")
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(isSending || input.trimmingCharacters(in: .whitespaces).isEmpty || project.compositionSource.isEmpty)
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func messageRow(_ msg: RemotionMessage) -> some View {
        let isUser = msg.role == RemotionMessageRole.user.rawValue
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(msg.content)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                )
                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            if !isUser { Spacer(minLength: 40) }
        }
    }

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
        Task {
            do {
                let newSource = try await RemotionCodeBuilder.applyEdit(
                    project: bindable,
                    userInstruction: instruction,
                    history: history,
                    config: config
                )
                try RemotionCodeBuilder.writeComposition(project: bindable, source: newSource)
                bindable.compositionSource = newSource
                bindable.updatedAt = Date()

                let assistantMsg = RemotionMessage(
                    role: RemotionMessageRole.assistant.rawValue,
                    content: "Updated Composition.tsx (\(newSource.count) chars).",
                    project: bindable
                )
                modelContext.insert(assistantMsg)
                bindable.messages.append(assistantMsg)
                reloadToken += 1
            } catch {
                errorMessage = error.localizedDescription
            }
            isSending = false
        }
    }
}
#endif
