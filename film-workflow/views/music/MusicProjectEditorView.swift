import SwiftUI

struct MusicProjectEditorView: View {
    @Bindable var project: MusicProject
    @State private var selectedTab: EditorTab = .structure

    private enum EditorTab: String, CaseIterable {
        case structure = "Structure"
        case lyrics = "Lyrics"
    }

    var body: some View {
        VStack(spacing: 0) {
            if project.inputModeEnum == .prompt {
                promptEditorContent
            } else {
                structuredEditorContent
            }
        }
    }

    private var promptEditorContent: some View {
        VStack(spacing: 0) {
            Text("Prompt")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            Divider()

            TextEditor(text: $project.promptText)
                .font(.body)
                .padding(8)
                .frame(maxHeight: .infinity)
        }
    }

    private var structuredEditorContent: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                ForEach(EditorTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            Group {
                switch selectedTab {
                case .structure:
                    ScrollView {
                        SongStructureEditorView(entries: $project.songStructureEntries)
                            .padding()
                    }

                case .lyrics:
                    if project.generationTypeEnum == .withLyrics {
                        ScrollView {
                            LyricsEditorView(entries: $project.lyricEntries)
                                .padding()
                        }
                    } else {
                        ContentUnavailableView(
                            "Lyrics Disabled",
                            systemImage: "text.quote",
                            description: Text("Switch generation type to \"With Lyrics\" to enable the lyrics editor.")
                        )
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
