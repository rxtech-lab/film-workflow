import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// A project the `@` popup can insert.
struct AgentTargetOption: Identifiable, Hashable {
    let kind: AgentTargetKind
    let projectUUID: UUID
    let name: String

    var id: String { "\(kind.rawValue):\(projectUUID.uuidString)" }
    var token: String { "@\(kind.rawValue):\(name)" }
}

/// Commands typed with a leading slash.
enum AgentSlashCommand: String, CaseIterable, Identifiable {
    case new
    case clear
    case compact
    case stop

    var id: String { rawValue }
    var command: String { "/\(rawValue)" }

    var summary: LocalizedStringKey {
        switch self {
        case .new: return "Start a new thread"
        case .clear: return "Delete every message in this thread"
        case .compact: return "Fold older turns into the summary now"
        case .stop: return "Stop the running turn"
        }
    }
}

/// The agent window's input box.
///
/// Modelled on rxcode's `InputBarView`. The behaviours that matter and why:
/// Enter sends while Shift+Enter inserts a newline; ↑ walks back through what
/// you have already asked; typing while a turn is running **queues** rather than
/// interrupting it; and `/` and `@` open completion popups that float above the
/// box rather than pushing the transcript around.
struct AgentComposer: View {
    @Bindable var thread: AgentThread
    let targets: [AgentTargetOption]
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void
    let onCommand: (AgentSlashCommand) -> Void

    @Environment(AgentController.self) private var controller

    @State private var isInputFocused = false
    @State private var focusTrigger: UUID?
    @State private var hasMarkedText = false
    @State private var measuredInputHeight: CGFloat = 20
    @State private var historyIndex = -1
    @State private var showSlashPopup = false
    @State private var slashSelectedIndex = 0
    @State private var showAtPopup = false
    @State private var atSelectedIndex = 0
    @State private var isDropTargeted = false
    @State private var modelCatalog = AgentModelCatalog.shared

    private var threadID: UUID { thread.id }
    private var run: AgentController.Run { controller.run(for: threadID) }

    private var text: Binding<String> {
        Binding(
            get: { controller.run(for: threadID).input },
            set: { controller.setInput($0, for: threadID) }
        )
    }

    var body: some View {
        VStack(spacing: 6) {
            queuedMessages
            composer
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            popups
                .padding(.horizontal, 12)
                // Map the top guide to the bottom so popups float above the box
                // instead of covering it.
                .alignmentGuide(.top) { $0[.bottom] }
        }
        .onChange(of: text.wrappedValue) { _, newValue in
            updatePopups(for: newValue)
        }
        // Fills the subscription engine's model submenu. Cheap after the first
        // load — the catalog is cached and shared with the settings pane.
        .task { await modelCatalog.loadSubscriptionChatModels(forceRefresh: false) }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(spacing: 6) {
            inputField
                .popoverTip(FilmWorkflowTips.AgentComposerTip(), arrowEdge: .top)
            actionRow
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor
                        : Color.secondary.opacity(isInputFocused ? 0.45 : 0.2),
                    lineWidth: 1
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .contentShape(Rectangle())
        .onTapGesture { focusTrigger = UUID() }
    }

    @ViewBuilder
    private var inputField: some View {
        #if os(macOS)
            ZStack(alignment: .topLeading) {
                AgentTextInput(
                    text: text,
                    isFocused: $isInputFocused,
                    hasMarkedText: $hasMarkedText,
                    focusTrigger: focusTrigger,
                    font: .systemFont(ofSize: NSFont.systemFontSize),
                    textColor: .labelColor,
                    placeholder: String(localized: "Ask for a change…"),
                    onReturn: handleReturn,
                    onUpArrow: handleUpArrow,
                    onDownArrow: handleDownArrow,
                    onTab: handleTab,
                    onEscape: handleEscape
                )
                .frame(height: clampedInputHeight)

                // NSScrollView has no intrinsic height, so a hidden Text at the
                // same font and width reports the wrapped height that drives it.
                InputHeightMeasurer(
                    text: text.wrappedValue,
                    measuredHeight: $measuredInputHeight
                )
            }
        #else
            TextField("Ask for a change…", text: text, axis: .vertical)
                .lineLimit(3 ... 10)
                .textFieldStyle(.plain)
                .onSubmit(handleReturn)
        #endif
    }

    private var clampedInputHeight: CGFloat {
        let oneLine: CGFloat = 20
        let minHeight: CGFloat = oneLine * 3
        let maxLines: CGFloat = 10
        return min(max(measuredInputHeight, minHeight), oneLine * maxLines)
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            backendMenu

            if isStreaming {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    Text("Working…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            // While streaming, the send button only appears once there is
            // something to enqueue; when idle it is always there, disabled when
            // empty.
            if !isStreaming || hasContent {
                Button(action: handleSend) {
                    Image(systemName: isStreaming ? "text.append" : "arrow.up.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!hasContent)
                .keyboardShortcut(.return, modifiers: .command)
                .help(isStreaming ? "Queue this message" : "Send")
            }

            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(".", modifiers: .command)
                .help("Stop")
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isStreaming)
    }

    private var hasContent: Bool {
        !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasMarkedText
    }

    /// Engine picker, with a nested model list for the backends that have one.
    ///
    /// The CLI backends get a submenu rather than a second control: model and
    /// engine are one decision here — a Claude alias means nothing to Codex —
    /// and picking a model necessarily picks its engine too.
    private var backendMenu: some View {
        Menu {
            Button {
                thread.backendOverride = nil
            } label: {
                if thread.backendOverride == nil {
                    Label("Default", systemImage: "checkmark")
                } else {
                    Text("Default")
                }
            }
            Divider()
            ForEach(AgentBackend.supported) { backend in
                if backend.isCommandLine || backend == .subscription {
                    Menu(backend.engineLabel) {
                        modelButton(backend: backend, model: nil)
                        Divider()
                        ForEach(modelCatalog.options(for: backend)) { option in
                            modelButton(backend: backend, model: option.id, name: option.displayName)
                        }
                    }
                } else {
                    Button {
                        thread.backendOverride = backend
                    } label: {
                        if thread.backendOverride == backend {
                            Label(backend.displayName, systemImage: "checkmark")
                        } else {
                            Text(backend.displayName)
                        }
                    }
                }
            }
        } label: {
            Label {
                Text(backendMenuLabel)
            } icon: {
                Image(systemName: "sparkles")
            }
            .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// One row in a CLI backend's model submenu. `model: nil` is the row that
    /// clears the thread's override and falls back to Settings.
    @ViewBuilder
    private func modelButton(
        backend: AgentBackend,
        model: String?,
        name: String? = nil
    ) -> some View {
        let isSelected = controller.backend(for: thread) == backend
            && thread.modelOverride(for: backend) == model
        Button {
            thread.backendOverride = backend
            thread.setModelOverride(model, for: backend)
        } label: {
            if isSelected {
                Label(name ?? "Default model", systemImage: "checkmark")
            } else {
                Text(name ?? "Default model")
            }
        }
    }

    /// "Codex · GPT-5.6-Sol" when the thread pins a model, the engine name alone
    /// otherwise — the Settings-level model belongs in Settings, not on a button
    /// the user didn't set.
    private var backendMenuLabel: String {
        let backend = controller.backend(for: thread)
        guard let model = thread.modelOverride(for: backend), !model.isEmpty else {
            return backend.engineLabel
        }
        return "\(backend.engineLabel) · \(modelCatalog.displayName(for: model, backend: backend))"
    }

    // MARK: - Queued messages

    @ViewBuilder
    private var queuedMessages: some View {
        let queued = run.queued
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("^[\(queued.count) message](inflect: true) queued")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if queued.count > 1 {
                        Button("Send all as one") {
                            controller.mergeQueued(for: threadID)
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                }
                ForEach(Array(queued.enumerated()), id: \.offset) { index, message in
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(message)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Button {
                            controller.removeQueued(at: index, for: threadID)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.secondary.opacity(0.08))
                    )
                }
            }
        }
    }

    // MARK: - Popups

    @ViewBuilder
    private var popups: some View {
        if showSlashPopup, !filteredCommands.isEmpty {
            popupList(filteredCommands, selected: slashSelectedIndex) { command in
                HStack {
                    Text(command.command)
                        .font(.caption.monospaced())
                    Text(command.summary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        } else if showAtPopup, !filteredTargets.isEmpty {
            popupList(filteredTargets, selected: atSelectedIndex) { option in
                HStack(spacing: 6) {
                    Image(systemName: option.kind.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(option.name)
                        .font(.caption)
                    Text(option.kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func popupList<Item: Identifiable, Row: View>(
        _ items: [Item],
        selected: Int,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == selected ? Color.accentColor.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                    .onTapGesture { commit(index: index) }
            }
        }
        .frame(maxHeight: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(radius: 8, y: 2)
        .padding(.bottom, 6)
    }

    // MARK: - Popup state

    private var slashQuery: String {
        text.wrappedValue.trimmingCharacters(in: .whitespaces)
    }

    private var filteredCommands: [AgentSlashCommand] {
        let query = slashQuery.dropFirst().lowercased()
        guard !query.isEmpty else { return AgentSlashCommand.allCases }
        return AgentSlashCommand.allCases.filter { $0.rawValue.hasPrefix(query) }
    }

    private var atQuery: String {
        guard let range = text.wrappedValue.range(of: "@", options: .backwards) else { return "" }
        return String(text.wrappedValue[range.upperBound...])
    }

    private var filteredTargets: [AgentTargetOption] {
        let query = atQuery.lowercased()
        guard !query.isEmpty else { return targets }
        return targets.filter {
            $0.name.lowercased().contains(query) || $0.kind.rawValue.lowercased().hasPrefix(query)
        }
    }

    private func updatePopups(for value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        let showSlash = trimmed.hasPrefix("/") && !value.contains(" ") && !value.contains("\n")
        if showSlash != showSlashPopup {
            showSlashPopup = showSlash
            slashSelectedIndex = 0
        }

        // An `@` opens the picker until a space closes the query.
        let showAt: Bool
        if !showSlash, let range = value.range(of: "@", options: .backwards) {
            let tail = value[range.upperBound...]
            showAt = !tail.contains(" ") && !tail.contains("\n")
        } else {
            showAt = false
        }
        if showAt != showAtPopup {
            showAtPopup = showAt
            atSelectedIndex = 0
        }
    }

    private func commit(index: Int) {
        if showSlashPopup {
            guard filteredCommands.indices.contains(index) else { return }
            let command = filteredCommands[index]
            showSlashPopup = false
            controller.setInput("", for: threadID)
            onCommand(command)
        } else if showAtPopup {
            guard filteredTargets.indices.contains(index) else { return }
            let option = filteredTargets[index]
            if let range = text.wrappedValue.range(of: "@", options: .backwards) {
                var updated = text.wrappedValue
                updated.replaceSubrange(range.lowerBound..., with: option.token + " ")
                controller.setInput(updated, for: threadID)
            }
            // Picking a project in the composer retargets a thread that has none
            // yet, so "@Ep 12 fix the spelling" works as one action.
            if thread.target.isEmpty {
                thread.target = AgentTarget(kind: option.kind, projectUUID: option.projectUUID)
            }
            showAtPopup = false
            focusTrigger = UUID()
        }
    }

    // MARK: - Key handling

    private func handleReturn() {
        if showSlashPopup, !filteredCommands.isEmpty {
            commit(index: slashSelectedIndex)
            return
        }
        if showAtPopup, !filteredTargets.isEmpty {
            commit(index: atSelectedIndex)
            return
        }
        handleSend()
    }

    private func handleSend() {
        guard hasContent else { return }
        historyIndex = -1
        showSlashPopup = false
        showAtPopup = false
        onSend()
    }

    private func handleTab() -> Bool {
        if showSlashPopup, !filteredCommands.isEmpty {
            commit(index: slashSelectedIndex)
            return true
        }
        if showAtPopup, !filteredTargets.isEmpty {
            commit(index: atSelectedIndex)
            return true
        }
        return false
    }

    private func handleEscape() -> Bool {
        if showSlashPopup || showAtPopup {
            showSlashPopup = false
            showAtPopup = false
            return true
        }
        // Escape pops the last queued message before it cancels the turn, so an
        // accidental queue is cheap to undo.
        let queued = run.queued
        if !queued.isEmpty {
            controller.removeQueued(at: queued.count - 1, for: threadID)
            return true
        }
        if isStreaming {
            onStop()
            return true
        }
        return false
    }

    private func handleUpArrow() -> Bool {
        if showSlashPopup, !filteredCommands.isEmpty {
            slashSelectedIndex = (slashSelectedIndex - 1 + filteredCommands.count) % filteredCommands.count
            return true
        }
        if showAtPopup, !filteredTargets.isEmpty {
            atSelectedIndex = (atSelectedIndex - 1 + filteredTargets.count) % filteredTargets.count
            return true
        }
        return recallHistory(offset: 1)
    }

    private func handleDownArrow() -> Bool {
        if showSlashPopup, !filteredCommands.isEmpty {
            slashSelectedIndex = (slashSelectedIndex + 1) % filteredCommands.count
            return true
        }
        if showAtPopup, !filteredTargets.isEmpty {
            atSelectedIndex = (atSelectedIndex + 1) % filteredTargets.count
            return true
        }
        return recallHistory(offset: -1)
    }

    /// Walks the thread's own user turns, newest first.
    private func recallHistory(offset: Int) -> Bool {
        let history = thread.orderedMessages
            .filter { $0.roleEnum == .user && $0.kindEnum == .text }
            .map(\.content)
            .reversed()
            .map { $0 }
        guard !history.isEmpty else { return false }

        // Only start recalling from an empty box, so ↑ inside a draft still
        // moves the caret.
        if historyIndex == -1, !text.wrappedValue.isEmpty { return false }

        let next = historyIndex + offset
        guard next >= -1, next < history.count else { return true }
        historyIndex = next
        controller.setInput(next == -1 ? "" : history[next], for: threadID)
        return true
    }

    // MARK: - Drop

    /// Dropping a file inserts its path. Tools take paths, so this is directly
    /// usable — "transcribe @path" or "add this image to the composition".
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var updated = controller.run(for: threadID).input
                    if !updated.isEmpty, !updated.hasSuffix(" ") { updated += " " }
                    updated += url.path
                    controller.setInput(updated, for: threadID)
                    focusTrigger = UUID()
                }
            }
        }
        return handled
    }
}

#if os(macOS)
    /// Reports the height a wrapped `Text` would take at the composer's width, so
    /// the hosted `NSScrollView` can be sized to fit its content.
    private struct InputHeightMeasurer: View {
        let text: String
        @Binding var measuredHeight: CGFloat

        var body: some View {
            Text(measuringText)
                .font(.system(size: NSFont.systemFontSize))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .hidden()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    guard abs(height - measuredHeight) > 0.5 else { return }
                    measuredHeight = height
                }
        }

        /// A trailing newline has zero intrinsic height through `Text`, so append a
        /// space to force the empty final line to be measured. The length cap is
        /// harmless because the height saturates at ten lines anyway.
        private var measuringText: String {
            if text.isEmpty { return " " }
            let capped = text.count > 2000 ? String(text.prefix(2000)) : text
            return capped.hasSuffix("\n") ? capped + " " : capped
        }
    }
#endif
