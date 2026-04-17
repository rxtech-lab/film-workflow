import SwiftUI

struct ShortcodeChipStrip: View {
    @Binding var text: String
    let provider: NarrativeProvider

    @State private var editingToken: EditingToken?

    struct EditingToken: Identifiable {
        let id = UUID()
        let occurrenceIndex: Int
        var name: String
        var args: [String]
        var wrapped: String?
    }

    private var tokens: [TokenMatch] { ShortcodeExpander.tokenMatches(in: text) }

    var body: some View {
        if tokens.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        ShortcodeChip(token: token) {
                            editingToken = EditingToken(
                                occurrenceIndex: index,
                                name: token.name,
                                args: token.args,
                                wrapped: token.wrapped
                            )
                        } onDelete: {
                            deleteToken(at: index)
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .popover(item: $editingToken, arrowEdge: .top) { editing in
                #if os(iOS)
                NavigationStack {
                    ShortcodeEditForm(
                        initialName: editing.name,
                        initialArgs: editing.args,
                        initialWrapped: editing.wrapped,
                        provider: provider
                    ) { newName, newArgs, newWrapped in
                        let serialized = ShortcodeExpander.serialize(name: newName, args: newArgs, wrapped: newWrapped)
                        replaceToken(at: editing.occurrenceIndex, with: serialized)
                        editingToken = nil
                    } onDelete: {
                        deleteToken(at: editing.occurrenceIndex)
                        editingToken = nil
                    } onCancel: {
                        editingToken = nil
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
                    replaceToken(at: editing.occurrenceIndex, with: serialized)
                    editingToken = nil
                } onDelete: {
                    deleteToken(at: editing.occurrenceIndex)
                    editingToken = nil
                } onCancel: {
                    editingToken = nil
                }
                #endif
            }
        }
    }

    private func replaceToken(at occurrenceIndex: Int, with newRaw: String) {
        let matches = ShortcodeExpander.tokenMatches(in: text)
        guard matches.indices.contains(occurrenceIndex) else { return }
        let range = matches[occurrenceIndex].range
        let ns = text as NSString
        text = ns.replacingCharacters(in: range, with: newRaw)
    }

    private func deleteToken(at occurrenceIndex: Int) {
        let matches = ShortcodeExpander.tokenMatches(in: text)
        guard matches.indices.contains(occurrenceIndex) else { return }
        var range = matches[occurrenceIndex].range
        // Also remove a preceding '@' if present
        if range.location > 0,
           (text as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) == "@" {
            range = NSRange(location: range.location - 1, length: range.length + 1)
        }
        let ns = text as NSString
        text = ns.replacingCharacters(in: range, with: "")
    }
}

struct ShortcodeChip: View {
    let token: TokenMatch
    let onTap: () -> Void
    let onDelete: () -> Void

    private var schema: ShortcodeSchema {
        ShortcodeExpander.schema(forName: token.name)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                onTap()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: schema.iconName)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(ShortcodeExpander.chipSummary(name: token.name, args: token.args, wrapped: token.wrapped))
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.accentColor.opacity(0.14))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
        )
    }
}

struct ShortcodeEditForm: View {
    @State var name: String
    @State var args: [String]
    @State var wrappedValue: String
    @State private var hasWrapped: Bool
    @State private var customArgIndices: Set<Int>

    private let provider: NarrativeProvider
    private let onSave: (String, [String], String?) -> Void
    private let onDelete: () -> Void
    private let onCancel: () -> Void

    private var schema: ShortcodeSchema {
        ShortcodeExpander.schema(forName: name)
    }

    init(
        initialName: String,
        initialArgs: [String],
        initialWrapped: String?,
        provider: NarrativeProvider,
        onSave: @escaping (String, [String], String?) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.provider = provider
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: initialName)

        let initialSchema = ShortcodeExpander.schema(forName: initialName)
        var paddedArgs = initialArgs
        while paddedArgs.count < initialSchema.args.count { paddedArgs.append("") }
        _args = State(initialValue: paddedArgs)

        _wrappedValue = State(initialValue: initialWrapped ?? "")
        _hasWrapped = State(initialValue: initialWrapped != nil)

        // If an existing value doesn't match any suggestion, show a free-text field for it.
        var custom: Set<Int> = []
        for (i, field) in initialSchema.args.enumerated() where !field.suggestions.isEmpty {
            let value = i < paddedArgs.count ? paddedArgs[i] : ""
            if !value.isEmpty && !field.suggestions.contains(value) {
                custom.insert(i)
            }
        }
        _customArgIndices = State(initialValue: custom)
    }

    private func selectShortcode(_ newName: String) {
        guard newName != name else { return }
        name = newName
        let newSchema = ShortcodeExpander.schema(forName: newName)
        args = Array(repeating: "", count: newSchema.args.count)
        customArgIndices = []
        if newSchema.wrappedField == nil {
            wrappedValue = ""
            hasWrapped = false
        }
    }

    private var shortcodeSelector: some View {
        Menu {
            ForEach(ShortcodeExpander.uniqueSchemasGrouped(for: provider), id: \.category) { group in
                Section(group.category.rawValue) {
                    ForEach(group.items, id: \.name) { item in
                        Button {
                            selectShortcode(item.name)
                        } label: {
                            Label(item.displayName, systemImage: item.iconName)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: schema.iconName)
                    .foregroundStyle(Color.accentColor)
                Text(schema.displayName)
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(0.12))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    func performSave() {
        let trimmed = args.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let wrappedOut: String?
        if schema.wrappedField != nil || hasWrapped {
            wrappedOut = wrappedValue
        } else {
            wrappedOut = nil
        }
        onSave(name.trimmingCharacters(in: .whitespaces), trimmed, wrappedOut)
    }

    var body: some View {
        #if os(iOS)
        Form {
            Section {
                HStack {
                    Text("Shortcode")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    shortcodeSelector
                }

                ForEach(Array(schema.args.enumerated()), id: \.offset) { index, field in
                    argRow(index: index, field: field)
                }

                if schema.wrappedField != nil || !wrappedValue.isEmpty || hasWrapped {
                    wrappedRow
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .destructiveAction) {
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button { performSave() } label: {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                }
            }
        }
        #else
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Shortcode").frame(width: 110, alignment: .leading)
                        .font(.caption).foregroundStyle(.secondary)
                    shortcodeSelector
                    Spacer()
                }

                ForEach(Array(schema.args.enumerated()), id: \.offset) { index, field in
                    argRow(index: index, field: field)
                }

                if schema.wrappedField != nil || !wrappedValue.isEmpty || hasWrapped {
                    wrappedRow
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(minWidth: 360)
        .frame(maxWidth: 420)
        #endif
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: schema.iconName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(schema.displayName)
                    .font(.headline)
                Text("Edit shortcode parameters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func argRow(index: Int, field: ShortcodeSchema.ArgField) -> some View {
        HStack(spacing: 6) {
            Text(field.label).frame(width: 110, alignment: .leading)
                .font(.caption).foregroundStyle(.secondary)

            if field.suggestions.isEmpty || customArgIndices.contains(index) {
                argTextField(index: index, field: field)
                if !field.suggestions.isEmpty {
                    Button {
                        customArgIndices.remove(index)
                    } label: {
                        Image(systemName: "list.bullet")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            } else {
                argDropdown(index: index, field: field)
            }
        }
    }

    private func argTextField(index: Int, field: ShortcodeSchema.ArgField) -> some View {
        TextField(field.placeholder, text: Binding(
            get: { index < args.count ? args[index] : "" },
            set: { newValue in
                while args.count <= index { args.append("") }
                args[index] = newValue
            }
        ))
        .textFieldStyle(.roundedBorder)
        .disableAutocorrection(true)
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
    }

    @ViewBuilder
    private func argDropdown(index: Int, field: ShortcodeSchema.ArgField) -> some View {
        let currentValue = index < args.count ? args[index] : ""
        Menu {
            ForEach(field.suggestions, id: \.self) { suggestion in
                Button {
                    while args.count <= index { args.append("") }
                    args[index] = suggestion
                } label: {
                    HStack {
                        Text(suggestion.isEmpty ? "(empty)" : suggestion)
                        if suggestion == currentValue {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
            Button("Custom…") {
                customArgIndices.insert(index)
            }
        } label: {
            HStack(spacing: 6) {
                Text(dropdownLabel(for: currentValue, placeholder: field.placeholder))
                    .foregroundStyle(currentValue.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformControlBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
    }

    private func dropdownLabel(for value: String, placeholder: String) -> String {
        if value.isEmpty { return placeholder.isEmpty ? "Select…" : placeholder }
        return value
    }

    private var wrappedRow: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(schema.wrappedField?.label ?? "Text")
                .frame(width: 110, alignment: .leading)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.top, 6)
            TextField(
                schema.wrappedField?.placeholder ?? "",
                text: $wrappedValue,
                axis: .vertical
            )
            .lineLimit(1...4)
            .textFieldStyle(.roundedBorder)
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("Cancel") { onCancel() }
                .keyboardShortcut(.cancelAction)

            Button {
                performSave()
            } label: {
                Label("Save", systemImage: "checkmark")
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
    }
}
