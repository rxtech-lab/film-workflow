import SwiftData
import SwiftUI

/// The project glossary, shown in the caption setup panel beside the speakers.
///
/// Kept in its own file rather than added to `CaptionProjectParametersView`
/// because it owns three pieces of editing state and a sheet; folding that into
/// a view that already manages audio import, speaker renames and provider
/// selection would make both harder to follow.
struct CaptionTermsSection: View {
    @Bindable var project: CaptionProject

    @State private var editingTerm: CaptionTerm?
    @State private var deletingTerm: CaptionTerm?
    @State private var showPasteSheet = false
    @State private var pasteDraft = ""

    var body: some View {
        Section {
            ForEach(project.terms) { term in
                Button {
                    editingTerm = term
                } label: {
                    row(term)
                }
                .buttonStyle(.plain)
                #if os(iOS)
                .swipeActions(edge: .trailing) {
                    Button("Delete…", role: .destructive) { deletingTerm = term }
                }
                #endif
                .contextMenu {
                    Button("Edit…") { editingTerm = term }
                    Button("Delete…", role: .destructive) { deletingTerm = term }
                }
            }

            HStack {
                Button {
                    let term = CaptionTerm(text: "")
                    project.terms.append(term)
                    project.updatedAt = Date()
                    editingTerm = term
                } label: {
                    Label("Add Term", systemImage: "plus")
                }

                Spacer()

                Button {
                    pasteDraft = ""
                    showPasteSheet = true
                } label: {
                    Label("Paste List", systemImage: "doc.on.clipboard")
                }
            }
            .font(.caption)
        } header: {
            Text("Terms")
        } footer: {
            Text("""
                Names and jargon this recording uses. Speech recognition often gets them wrong; \
                listing them here lets the AI review find and fix those mistakes, and keeps a term \
                from being split across two captions.
                """)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .sheet(item: $editingTerm) { term in
            CaptionTermEditorSheet(project: project, termID: term.id)
        }
        .sheet(isPresented: $showPasteSheet) {
            pasteSheet
        }
        .confirmationDialog(
            "Delete this glossary term?",
            isPresented: Binding(
                get: { deletingTerm != nil },
                set: { if !$0 { deletingTerm = nil } }
            ),
            titleVisibility: .visible,
            presenting: deletingTerm
        ) { term in
            Button("Delete Term", role: .destructive) {
                delete(term)
                deletingTerm = nil
            }
            Button("Cancel", role: .cancel) { deletingTerm = nil }
        } message: { term in
            Text("\"\(term.text)\" and its known spelling variants will be permanently deleted.")
        }
    }

    // MARK: - Rows

    private func row(_ term: CaptionTerm) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                // Built as two `Text`s rather than one ternary over a String:
                // a String argument takes Text's verbatim initializer and is
                // never localized.
                if term.text.isEmpty {
                    Text("Untitled term")
                        .foregroundStyle(.secondary)
                } else {
                    Text(term.text)
                }
                if !term.note.isEmpty {
                    Text(term.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !term.variants.isEmpty {
                Text("Variants: \(term.variants.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }

    private var pasteSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Terms")
                .font(.headline)
            Text("One term per line, or separated by commas.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $pasteDraft)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator)
                )

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showPasteSheet = false }
                Button("Add") { commitPaste() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(parsedPaste.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 380)
    }

    // MARK: - Actions

    private var parsedPaste: [String] {
        pasteDraft
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == "，" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func commitPaste() {
        // Case-insensitive dedupe against what's already there, so pasting the
        // same list twice is a no-op rather than a pile of duplicates.
        let existing = Set(project.terms.map { $0.text.lowercased() })
        var added = project.terms
        for text in parsedPaste where !existing.contains(text.lowercased()) {
            added.append(CaptionTerm(text: text))
        }
        project.terms = added
        project.updatedAt = Date()
        showPasteSheet = false
    }

    private func delete(_ term: CaptionTerm) {
        project.terms.removeAll { $0.id == term.id }
        project.updatedAt = Date()
    }
}

/// Edits one glossary entry.
///
/// Addresses the term by id rather than holding a copy: `terms` is a value array
/// on the model, so a captured struct would go stale the moment anything else
/// touched the list.
struct CaptionTermEditorSheet: View {
    @Bindable var project: CaptionProject
    let termID: UUID

    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var note = ""
    @State private var variants: [String] = []
    @State private var newVariant = ""
    @State private var didLoad = false
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("Term", text: $text)
                    TextField("Note (optional)", text: $note)
                } header: {
                    Text("Spelling")
                } footer: {
                    Text("The note tells the model what this is — \"company name\", \"drug name\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(Array(variants.enumerated()), id: \.offset) { index, variant in
                        HStack {
                            Text(variant)
                            Spacer()
                            Button {
                                variants.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        TextField("Add a wrong spelling", text: $newVariant)
                            .onSubmit(addVariant)
                        Button("Add", action: addVariant)
                            .buttonStyle(.borderless)
                            .disabled(newVariant.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } header: {
                    Text("Known mistakes")
                } footer: {
                    Text("""
                        Spellings you've seen the transcriber produce for this term. Optional — the \
                        review still catches near-misses without them.
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Delete…", role: .destructive) { showDeleteConfirmation = true }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .frame(minWidth: 420, minHeight: 460)
        .onAppear(perform: load)
        .confirmationDialog(
            "Delete this glossary term?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Term", role: .destructive) {
                project.terms.removeAll { $0.id == termID }
                project.updatedAt = Date()
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The term and its known spelling variants will be permanently deleted.")
        }
    }

    private func addVariant() {
        let trimmed = newVariant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !variants.contains(trimmed) else { return }
        variants.append(trimmed)
        newVariant = ""
    }

    private func load() {
        guard !didLoad, let term = project.terms.first(where: { $0.id == termID }) else { return }
        didLoad = true
        text = term.text
        note = term.note
        variants = term.variants
    }

    private func save() {
        guard let index = project.terms.firstIndex(where: { $0.id == termID }) else {
            dismiss()
            return
        }
        var updated = project.terms
        updated[index].text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated[index].variants = variants
        project.terms = updated
        project.updatedAt = Date()
        dismiss()
    }
}
