import SwiftData
import SwiftUI

/// A language label for existing text; choosing it does not translate the text.
struct CaptionLanguagePicker: View {
    let title: LocalizedStringKey
    let language: String
    let onSelect: (String) throws -> Void
    @State private var customLanguage = ""
    @State private var showingCustom = false
    @State private var error: String?

    private static let customTag = "__custom__"
    private var selectedCode: String { (try? CaptionLanguage.normalized(language)) ?? language }
    private var codes: [String] {
        var codes = Set(CaptionLanguage.commonCodes)
        if !selectedCode.isEmpty { codes.insert(selectedCode) }
        return codes.sorted {
            CaptionTranslationAvailability.displayName($0).localizedStandardCompare(CaptionTranslationAvailability.displayName($1)) == .orderedAscending
        }
    }

    var body: some View {
        Picker(title, selection: Binding(get: { selectedCode }, set: choose)) {
            Text("Not set").tag("")
            ForEach(codes, id: \.self) { code in Text(CaptionTranslationAvailability.displayName(code)).tag(code) }
            Divider()
            Text("Other…").tag(Self.customTag)
        }
        .pickerStyle(.menu)
        .alert("Set Language", isPresented: $showingCustom) {
            TextField("Language code, e.g. en or zh-Hans", text: $customLanguage)
            Button("Cancel", role: .cancel) { }
            Button("Set Language") { save(customLanguage) }
        } message: {
            Text("Set the language of the existing text. Its wording and timings stay the same.")
        }
        .alert("Couldn’t Set Language", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func choose(_ code: String) {
        if code == Self.customTag {
            customLanguage = selectedCode
            showingCustom = true
        } else { save(code) }
    }

    private func save(_ code: String) {
        do { try onSelect(CaptionLanguage.normalized(code)) }
        catch { self.error = error.localizedDescription }
    }
}

struct CaptionSourceLanguagePicker: View {
    let project: CaptionProject
    @Environment(\.modelContext) private var context

    var body: some View {
        CaptionLanguagePicker(title: "Original language", language: project.sourceLanguageCode) { code in
            try CaptionLanguage.setOriginal(code, for: project, context: context)
        }
        .controlSize(.small)
        .help("The language of the original text in this version, used for lyrics and publishing.")
        .accessibilityIdentifier("caption-original-language")
    }
}
