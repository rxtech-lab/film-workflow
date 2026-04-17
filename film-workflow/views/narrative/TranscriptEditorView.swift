
import SwiftUI

struct TranscriptEditorView: View {
    @Bindable var project: NarrativeProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            stickyHeader
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .background(.bar)

            Divider()

            if project.paragraphs.isEmpty {
                ContentUnavailableView(
                    "No Paragraphs",
                    systemImage: "text.bubble",
                    description: Text("Add a paragraph for a speaker to start building your transcript.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach($project.paragraphs) { $paragraph in
                                NarrativeParagraphRow(
                                    paragraph: $paragraph,
                                    speakers: project.speakers,
                                    provider: project.providerEnum,
                                    onDelete: {
                                        withAnimation {
                                            project.paragraphs.removeAll { $0.id == paragraph.id }
                                            project.updatedAt = Date()
                                        }
                                    }
                                )
                                .id(paragraph.id)
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: project.paragraphs.count) { oldValue, newValue in
                        guard newValue > oldValue, let last = project.paragraphs.last else { return }
                        DispatchQueue.main.async {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }

    private var stickyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Transcript")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(project.speakers) { speaker in
                    Button {
                        addParagraph(for: speaker.id)
                    } label: {
                        Label("+ \(speaker.displayName)", systemImage: "plus.bubble")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func addParagraph(for speakerId: UUID) {
        let paragraph = NarrativeParagraph(
            speakerId: speakerId,
            emotion: "",
            content: ""
        )
        withAnimation {
            project.paragraphs.append(paragraph)
            project.updatedAt = Date()
        }
    }
}

struct NarrativeParagraphRow: View {
    @Binding var paragraph: NarrativeParagraph
    let speakers: [NarrativeSpeaker]
    let provider: NarrativeProvider
    var onDelete: () -> Void

    @State private var isCustomEmotion: Bool = false
    @State private var customEmotionDraft: String = ""
    @State private var azureStore = AzureVoiceStore.shared
    @State private var showShortcodePicker: Bool = false
    @State private var shortcodeSelection: Int = 0
    @State private var selectionFromKeyboard: Bool = false
    @State private var attributedContent: AttributedString = .init()
    @State private var textSelection: AttributedTextSelection = .init()
    @State private var atTriggerOffset: Int?
    @State private var inlineEditing: InlineEditState?
    @State private var lastInsideTokenIndex: Int?
    @FocusState private var shortcodeListFocused: Bool

    struct InlineEditState: Identifiable {
        let id = UUID()
        let occurrenceIndex: Int
        let name: String
        let args: [String]
        let wrapped: String?
    }

    private var currentSpeaker: NarrativeSpeaker? {
        speakers.first { $0.id == paragraph.speakerId }
    }

    private var speakerLabel: String {
        guard let speaker = currentSpeaker else { return "Narrator" }
        switch provider {
        case .gemini:
            return "\(speaker.displayName) - \(speaker.voiceEnum.rawValue)"
        case .azure:
            return "\(speaker.displayName) - \(speaker.voice)"
        }
    }

    private var azureStylesForCurrentSpeaker: [String] {
        guard provider == .azure, let speaker = currentSpeaker else { return [] }
        return azureStore.voice(forShortName: speaker.voice)?.styleList ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            Divider()

            bodyRow
                .padding(16)
        }
        .background(Color.platformControlBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var headerRow: some View {
        HStack {
            Menu {
                ForEach(speakers) { speaker in
                    Button {
                        paragraph.speakerId = speaker.id
                        // Reset emotion if incoming voice doesn't support it (Azure).
                        if provider == .azure {
                            let allowed = azureStore.voice(forShortName: speaker.voice)?.styleList ?? []
                            if !paragraph.emotion.isEmpty, !allowed.contains(paragraph.emotion) {
                                paragraph.emotion = ""
                            }
                        }
                    } label: {
                        switch provider {
                        case .gemini:
                            Text("\(speaker.displayName) - \(speaker.voiceEnum.rawValue)")
                        case .azure:
                            Text("\(speaker.displayName) - \(speaker.voice)")
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "person")
                    Text(speakerLabel)
                        .font(.subheadline)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.platformControlBackground)
                .clipShape(Capsule())
                .foregroundStyle(.primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    private var bodyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                emotionPicker
                shortcodeToolbarMenu
            }

            TextEditor(text: $attributedContent, selection: trackingSelection)
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color.platformControlBackground)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onAppear {
                    let styled = Self.styledAttributed(paragraph.content)
                    if String(attributedContent.characters) != paragraph.content {
                        attributedContent = styled
                    }
                }
                .onChange(of: attributedContent) { oldValue, newValue in
                    let oldPlain = String(oldValue.characters)
                    let newPlain = String(newValue.characters)
                    guard newPlain != paragraph.content else { return }

                    // Detect '@' typed — find insertion position by diffing old/new
                    if newPlain.count == oldPlain.count + 1 {
                        // Find the index where the character was inserted
                        var insertedOffset: Int?
                        let oldChars = Array(oldPlain)
                        let newChars = Array(newPlain)
                        for i in 0 ..< newChars.count {
                            if i >= oldChars.count || newChars[i] != oldChars[i] {
                                insertedOffset = i
                                break
                            }
                        }
                        if let offset = insertedOffset, newChars[offset] == "@" {
                            atTriggerOffset = offset
                            showShortcodePicker = true
                        }
                    }

                    // Detect if a shortcode was partially edited and remove the whole chip
                    let oldTokens = ShortcodeExpander.tokenMatches(in: oldPlain)
                    let newTokens = ShortcodeExpander.tokenMatches(in: newPlain)
                    let newRaws = Set(newTokens.map(\.raw))
                    let damagedTokens = oldTokens.filter { !newRaws.contains($0.raw) }

                    if !damagedTokens.isEmpty {
                        // Remove damaged tokens from the old text (in reverse to preserve ranges)
                        let ns = oldPlain as NSString
                        var cleaned = oldPlain
                        for token in damagedTokens.sorted(by: { $0.range.location > $1.range.location }) {
                            var removeRange = token.range
                            // Also remove a preceding '@' if present
                            if removeRange.location > 0,
                               (cleaned as NSString).substring(with: NSRange(location: removeRange.location - 1, length: 1)) == "@"
                            {
                                removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
                            }
                            if let swiftRange = Range(removeRange, in: cleaned) {
                                cleaned.removeSubrange(swiftRange)
                            }
                        }
                        paragraph.content = cleaned
                        let styled = Self.styledAttributed(cleaned)
                        attributedContent = styled
                        return
                    }

                    paragraph.content = newPlain

                    if oldTokens.map(\.range) != newTokens.map(\.range) {
                        attributedContent = Self.styledAttributed(newPlain)
                    }
                }
                .onChange(of: paragraph.content) { _, newValue in
                    if String(attributedContent.characters) != newValue {
                        attributedContent = Self.styledAttributed(newValue)
                    }
                }
                .popover(isPresented: $showShortcodePicker, arrowEdge: .top) {
                    #if os(iOS)
                    NavigationStack {
                        shortcodePopoverList(triggeredByAt: true)
                            .navigationTitle("Insert cue")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showShortcodePicker = false
                                    }
                                }
                            }
                    }
                    .presentationDetents([.large])
                    #else
                    shortcodePopoverList(triggeredByAt: true)
                    #endif
                }
                // Intercept keys on the TextEditor when the popover is open.
                // On macOS, focus may not fully transfer to the popover, so the
                // TextEditor can receive Enter (inserting a newline) before the
                // popover handles it, leaving the '@' behind.
                .onKeyPress(.return) {
                    guard showShortcodePicker else { return .ignored }
                    let flat = flatCatalog
                    guard flat.indices.contains(shortcodeSelection) else {
                        showShortcodePicker = false
                        return .handled
                    }
                    showShortcodePicker = false
                    insertShortcode(flat[shortcodeSelection].insertTemplate, stripTrailingAt: true)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    guard showShortcodePicker else { return .ignored }
                    let flat = flatCatalog
                    guard !flat.isEmpty else { return .handled }
                    selectionFromKeyboard = true
                    shortcodeSelection = max(0, shortcodeSelection - 1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard showShortcodePicker else { return .ignored }
                    let flat = flatCatalog
                    guard !flat.isEmpty else { return .handled }
                    selectionFromKeyboard = true
                    shortcodeSelection = min(flat.count - 1, shortcodeSelection + 1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    guard showShortcodePicker else { return .ignored }
                    stripTrailingAt()
                    showShortcodePicker = false
                    return .handled
                }
                // Treat shortcode chips as atomic for cursor navigation.
                .onKeyPress(.rightArrow) {
                    guard let offset = currentCaretOffset() else { return .ignored }
                    for match in ShortcodeExpander.tokenMatches(in: paragraph.content) {
                        let start = match.range.location
                        let end = start + match.range.length
                        if offset >= start && offset < end {
                            let safeEnd = min(end, attributedContent.characters.count)
                            let endIdx = attributedContent.characters.index(
                                attributedContent.startIndex, offsetBy: safeEnd
                            )
                            textSelection = .init(insertionPoint: endIdx)
                            return .handled
                        }
                    }
                    return .ignored
                }
                .onKeyPress(.leftArrow) {
                    guard let offset = currentCaretOffset() else { return .ignored }
                    for match in ShortcodeExpander.tokenMatches(in: paragraph.content) {
                        let start = match.range.location
                        let end = start + match.range.length
                        if offset > start && offset <= end {
                            let startIdx = attributedContent.characters.index(
                                attributedContent.startIndex, offsetBy: start
                            )
                            textSelection = .init(insertionPoint: startIdx)
                            return .handled
                        }
                    }
                    return .ignored
                }
                .onKeyPress(.delete) {
                    deleteAdjacentChip(forward: false) ? .handled : .ignored
                }
                .onKeyPress(.deleteForward) {
                    deleteAdjacentChip(forward: true) ? .handled : .ignored
                }
                .simultaneousGesture(
                    TapGesture().onEnded {
                        DispatchQueue.main.async {
                            openInlineEditorIfClickedOnToken()
                        }
                    }
                )
                .popover(item: $inlineEditing, arrowEdge: .top) { editing in
                    inlineEditorContent(for: editing)
                }

            ShortcodeChipStrip(text: $paragraph.content, provider: provider)
        }
    }

    private var shortcodeToolbarMenu: some View {
        Menu {
            ForEach(ShortcodeExpander.catalogGrouped(for: provider), id: \.category) { group in
                Section(group.category.rawValue) {
                    ForEach(group.items) { definition in
                        Button {
                            insertShortcode(definition.insertTemplate, stripTrailingAt: false)
                        } label: {
                            Label(definition.displayName, systemImage: definition.iconName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "at")
                    .font(.caption)
                Text("Insert")
                    .font(.caption)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.platformControlBackground)
            .clipShape(Capsule())
            .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var flatCatalog: [ShortcodeDefinition] {
        ShortcodeExpander.catalogGrouped(for: provider).flatMap(\.items)
    }

    @ViewBuilder
    private func shortcodePopoverList(triggeredByAt: Bool) -> some View {
        let groups = ShortcodeExpander.catalogGrouped(for: provider)
        let flat = flatCatalog
        VStack(alignment: .leading, spacing: 0) {
            popoverHeader(triggeredByAt: triggeredByAt)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.category) { group in
                            sectionHeader(group.category)
                            ForEach(group.items) { definition in
                                let idx = flat.firstIndex(of: definition) ?? 0
                                shortcodeRow(
                                    definition: definition,
                                    index: idx,
                                    isSelected: idx == shortcodeSelection,
                                    triggeredByAt: triggeredByAt
                                )
                                .id(idx)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
                #if os(macOS)
                .frame(maxHeight: 360)
                #endif
                .onChange(of: shortcodeSelection) { _, newValue in
                    guard selectionFromKeyboard else { return }
                    selectionFromKeyboard = false
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .frame(minWidth: 380)
        .focusable()
        .focused($shortcodeListFocused)
        .onAppear {
            shortcodeSelection = 0
            shortcodeListFocused = true
        }
        .onKeyPress(.upArrow) {
            guard !flat.isEmpty else { return .handled }
            selectionFromKeyboard = true
            shortcodeSelection = max(0, shortcodeSelection - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !flat.isEmpty else { return .handled }
            selectionFromKeyboard = true
            shortcodeSelection = min(flat.count - 1, shortcodeSelection + 1)
            return .handled
        }
        .onKeyPress(.return) {
            guard flat.indices.contains(shortcodeSelection) else { return .handled }
            showShortcodePicker = false
            insertShortcode(flat[shortcodeSelection].insertTemplate, stripTrailingAt: triggeredByAt)
            return .handled
        }
        .onKeyPress(.escape) {
            if triggeredByAt { stripTrailingAt() }
            showShortcodePicker = false
            return .handled
        }
    }

    private func popoverHeader(triggeredByAt: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "at")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            Text("Insert cue")
                .font(.subheadline.weight(.semibold))
            Spacer()
            #if os(macOS)
            HStack(spacing: 4) {
                keyboardKey("↑")
                keyboardKey("↓")
                Text("move")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                keyboardKey("⏎")
                Text("pick")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                keyboardKey("esc")
            }
            Button {
                if triggeredByAt { stripTrailingAt() }
                showShortcodePicker = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func keyboardKey(_ label: String) -> some View {
        Text(label)
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.platformControlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }

    private func sectionHeader(_ category: ShortcodeCategory) -> some View {
        HStack(spacing: 6) {
            Text(category.rawValue.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformControlBackground.opacity(0.5))
    }

    @ViewBuilder
    private func shortcodeRow(
        definition: ShortcodeDefinition,
        index: Int,
        isSelected: Bool,
        triggeredByAt: Bool
    ) -> some View {
        Button {
            showShortcodePicker = false
            insertShortcode(definition.insertTemplate, stripTrailingAt: triggeredByAt)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: definition.iconName)
                    .font(.system(size: 14))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text(definition.displayName)
                        .font(.body)
                        .foregroundStyle(isSelected ? Color.white : .primary)
                    Text(definition.descriptionText)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(definition.insertTemplate)
                    .font(.caption2.monospaced())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 140, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { shortcodeSelection = index }
        }
    }

    private func insertShortcode(_ template: String, stripTrailingAt: Bool) {
        let content = paragraph.content
        let caret = currentCaretOffset() ?? content.count
        let insertion = template + " "

        var replaceAtIndex: Int? = nil
        if stripTrailingAt {
            replaceAtIndex = findReplaceableAt(before: caret, in: content)
            if replaceAtIndex == nil,
               let stored = atTriggerOffset,
               stored < content.count,
               content[content.index(content.startIndex, offsetBy: stored)] == "@"
            {
                replaceAtIndex = stored
            }
        }
        atTriggerOffset = nil

        var updated = content
        let finalCursorOffset: Int
        if let atIdx = replaceAtIndex {
            let removeIdx = updated.index(updated.startIndex, offsetBy: atIdx)
            updated.remove(at: removeIdx)
            let insertIdx = updated.index(updated.startIndex, offsetBy: atIdx)
            updated.insert(contentsOf: insertion, at: insertIdx)
            finalCursorOffset = atIdx + insertion.count
        } else {
            let safeCaret = min(caret, updated.count)
            let insertIdx = updated.index(updated.startIndex, offsetBy: safeCaret)
            updated.insert(contentsOf: insertion, at: insertIdx)
            finalCursorOffset = safeCaret + insertion.count
        }

        paragraph.content = updated
        let styled = Self.styledAttributed(updated)
        attributedContent = styled
        let cursorIdx = styled.characters.index(
            styled.startIndex,
            offsetBy: min(finalCursorOffset, styled.characters.count)
        )
        textSelection = .init(insertionPoint: cursorIdx)
    }

    private func findReplaceableAt(before caret: Int, in text: String) -> Int? {
        let tokenRanges = ShortcodeExpander.tokenMatches(in: text).map(\.range)
        let chars = Array(text)
        guard !chars.isEmpty else { return nil }
        let lower = max(0, caret - 8)
        var i = min(caret - 1, chars.count - 1)
        while i >= lower {
            if chars[i] == "@" {
                let inToken = tokenRanges.contains { r in
                    i >= r.location && i < r.location + r.length
                }
                if !inToken { return i }
            }
            i -= 1
        }
        return nil
    }

    static func styledAttributed(_ plain: String) -> AttributedString {
        let ns = plain as NSString
        var result = AttributedString()
        var cursor = 0
        for (index, match) in ShortcodeExpander.tokenMatches(in: plain).enumerated() {
            if match.range.location > cursor {
                let before = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                result.append(AttributedString(before))
            }
            var chip = AttributedString(match.raw)
            chip.foregroundColor = Color.accentColor
            chip.backgroundColor = Color.accentColor.opacity(0.15)
            chip.font = .body.monospaced().weight(.medium)
            var chipAttrs = AttributeContainer()
            chipAttrs[ChipIndexKey.self] = index
            chip.mergeAttributes(chipAttrs)
            result.append(chip)
            cursor = match.range.location + match.range.length
        }
        if cursor < ns.length {
            let trailing = ns.substring(with: NSRange(location: cursor, length: ns.length - cursor))
            result.append(AttributedString(trailing))
        }
        return result
    }

    private func currentCaretOffset() -> Int? {
        let indices = textSelection.indices(in: attributedContent)
        guard case .insertionPoint(let caretIndex) = indices else { return nil }
        return attributedContent.characters.distance(
            from: attributedContent.startIndex,
            to: caretIndex
        )
    }

    private func deleteAdjacentChip(forward: Bool) -> Bool {
        let indices = textSelection.indices(in: attributedContent)
        guard case .insertionPoint(let caretIndex) = indices else {
            return false
        }

        let charOffset = attributedContent.characters.distance(
            from: attributedContent.startIndex,
            to: caretIndex
        )

        for match in ShortcodeExpander.tokenMatches(in: paragraph.content) {
            let start = match.range.location
            let end = start + match.range.length
            // Backspace: caret anywhere from just after start through the end
            // Forward delete: caret anywhere from start through just before end
            let hit = forward
                ? (charOffset >= start && charOffset < end)
                : (charOffset > start && charOffset <= end)
            if hit {
                var removeRange = match.range
                // Also remove a preceding '@' if present
                if removeRange.location > 0,
                   (paragraph.content as NSString).substring(with: NSRange(location: removeRange.location - 1, length: 1)) == "@"
                {
                    removeRange = NSRange(location: removeRange.location - 1, length: removeRange.length + 1)
                }
                let ns = paragraph.content as NSString
                paragraph.content = ns.replacingCharacters(in: removeRange, with: "")
                return true
            }
        }

        return false
    }

    private func stripTrailingAt() {
        if paragraph.content.hasSuffix("@") { paragraph.content.removeLast() }
    }

    private var trackingSelection: Binding<AttributedTextSelection> {
        Binding(
            get: { textSelection },
            set: { newValue in
                let oldCaret = currentCaretOffset()
                textSelection = newValue
                let newCaret = caretOffset(for: newValue, in: attributedContent)
                print("[inlineTap] selection.set oldCaret=\(String(describing: oldCaret)) newCaret=\(String(describing: newCaret))")
                if oldCaret != newCaret {
                    DispatchQueue.main.async {
                        openInlineEditorIfClickedOnToken()
                    }
                }
            }
        )
    }

    private func caretOffset(for selection: AttributedTextSelection, in content: AttributedString) -> Int? {
        let indices = selection.indices(in: content)
        guard case .insertionPoint(let caretIndex) = indices else { return nil }
        return content.characters.distance(from: content.startIndex, to: caretIndex)
    }

    private func openInlineEditorIfClickedOnToken() {
        print("[inlineTap] fired. inlineEditing=\(inlineEditing == nil ? "nil" : "set")")
        guard inlineEditing == nil else {
            print("[inlineTap] already editing; skip")
            return
        }
        guard let caret = currentCaretOffset() else {
            print("[inlineTap] no caret offset (no insertion point)")
            return
        }
        let tokens = ShortcodeExpander.tokenMatches(in: paragraph.content)
        print("[inlineTap] caret=\(caret) tokenCount=\(tokens.count) content=\(paragraph.content)")
        for (index, match) in tokens.enumerated() {
            let start = match.range.location
            let end = start + match.range.length
            print("[inlineTap]   token[\(index)] name=\(match.name) range=[\(start),\(end)) raw=\(match.raw)")
            if caret > start && caret <= end {
                print("[inlineTap]   -> MATCH, presenting popover for token[\(index)]")
                inlineEditing = InlineEditState(
                    occurrenceIndex: index,
                    name: match.name,
                    args: match.args,
                    wrapped: match.wrapped
                )
                let safeEnd = min(end, attributedContent.characters.count)
                let endIdx = attributedContent.characters.index(
                    attributedContent.startIndex, offsetBy: safeEnd
                )
                textSelection = .init(insertionPoint: endIdx)
                return
            }
        }
        print("[inlineTap] caret not inside any token")
    }

    private func replaceInlineToken(at occurrenceIndex: Int, with newRaw: String) {
        let matches = ShortcodeExpander.tokenMatches(in: paragraph.content)
        guard matches.indices.contains(occurrenceIndex) else { return }
        let range = matches[occurrenceIndex].range
        let ns = paragraph.content as NSString
        paragraph.content = ns.replacingCharacters(in: range, with: newRaw)
    }

    private func deleteInlineToken(at occurrenceIndex: Int) {
        let matches = ShortcodeExpander.tokenMatches(in: paragraph.content)
        guard matches.indices.contains(occurrenceIndex) else { return }
        var range = matches[occurrenceIndex].range
        if range.location > 0,
           (paragraph.content as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == "@"
        {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        let ns = paragraph.content as NSString
        paragraph.content = ns.replacingCharacters(in: range, with: "")
    }

    @ViewBuilder
    private func inlineEditorContent(for editing: InlineEditState) -> some View {
        #if os(iOS)
        NavigationStack {
            ShortcodeEditForm(
                initialName: editing.name,
                initialArgs: editing.args,
                initialWrapped: editing.wrapped,
                provider: provider
            ) { newName, newArgs, newWrapped in
                let serialized = ShortcodeExpander.serialize(name: newName, args: newArgs, wrapped: newWrapped)
                replaceInlineToken(at: editing.occurrenceIndex, with: serialized)
                inlineEditing = nil
            } onDelete: {
                deleteInlineToken(at: editing.occurrenceIndex)
                inlineEditing = nil
            } onCancel: {
                inlineEditing = nil
            }
            .navigationTitle(ShortcodeExpander.schema(forName: editing.name).displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
        #else
        ShortcodeEditForm(
            initialName: editing.name,
            initialArgs: editing.args,
            initialWrapped: editing.wrapped,
            provider: provider
        ) { newName, newArgs, newWrapped in
            let serialized = ShortcodeExpander.serialize(name: newName, args: newArgs, wrapped: newWrapped)
            replaceInlineToken(at: editing.occurrenceIndex, with: serialized)
            inlineEditing = nil
        } onDelete: {
            deleteInlineToken(at: editing.occurrenceIndex)
            inlineEditing = nil
        } onCancel: {
            inlineEditing = nil
        }
        #endif
    }

    @ViewBuilder
    private var emotionPicker: some View {
        switch provider {
        case .gemini:
            geminiEmotionPicker
        case .azure:
            azureEmotionPicker
        }
    }

    private var geminiEmotionPicker: some View {
        HStack(spacing: 8) {
            Menu {
                Button("None") { paragraph.emotion = ""; isCustomEmotion = false }
                Divider()
                ForEach(EmotionPreset.allCases) { preset in
                    Button(preset.displayName) {
                        paragraph.emotion = preset.rawValue
                        isCustomEmotion = false
                    }
                }
                Divider()
                Button("Custom…") {
                    isCustomEmotion = true
                    customEmotionDraft = paragraph.emotion
                }
            } label: {
                HStack(spacing: 4) {
                    Text(emotionLabel)
                        .font(.caption.monospaced())
                    Image(systemName: "chevron.down")
                        .font(.caption2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.platformControlBackground)
                .clipShape(Capsule())
                .foregroundStyle(paragraph.emotion.isEmpty ? .secondary : .primary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            if isCustomEmotion {
                TextField("emotion", text: $customEmotionDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .onSubmit {
                        paragraph.emotion = customEmotionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        isCustomEmotion = false
                    }

                Button("Set") {
                    paragraph.emotion = customEmotionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                    isCustomEmotion = false
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var azureEmotionPicker: some View {
        let styles = azureStylesForCurrentSpeaker
        if styles.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 8) {
                Menu {
                    Button("None") { paragraph.emotion = "" }
                    Divider()
                    ForEach(styles, id: \.self) { style in
                        Button(style) { paragraph.emotion = style }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(emotionLabel)
                            .font(.caption.monospaced())
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.platformControlBackground)
                    .clipShape(Capsule())
                    .foregroundStyle(paragraph.emotion.isEmpty ? .secondary : .primary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()
            }
        }
    }

    private var emotionLabel: String {
        paragraph.emotion.isEmpty ? "[no emotion]" : "[\(paragraph.emotion)]"
    }
}

enum ChipIndexKey: AttributedStringKey {
    typealias Value = Int
    static let name = "filmChipIndex"
}
