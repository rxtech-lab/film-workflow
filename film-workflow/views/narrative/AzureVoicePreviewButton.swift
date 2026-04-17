import SwiftUI
import Translation

struct AzureVoicePreviewButton: View {
    let voice: AzureVoice?

    @State private var previewer = AzureVoicePreviewer.shared
    @State private var translationConfig: TranslationSession.Configuration?
    @State private var pendingVoice: AzureVoice?

    private static let sourceLanguage = Locale.Language(identifier: "en")

    var body: some View {
        let shortName = voice?.shortName ?? ""
        let isLoading = previewer.loadingVoice == shortName
        let isPlaying = previewer.playingVoice == shortName

        Button {
            onTap()
        } label: {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                }
            }
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderless)
        .disabled(voice == nil || isLoading)
        .help(isPlaying ? "Stop" : "Preview voice")
        .translationTask(translationConfig) { session in
            await runTranslation(session: session)
        }
    }

    private func onTap() {
        guard let voice else { return }

        // Toggle stop when this voice is already playing — sample text is unused.
        if previewer.playingVoice == voice.shortName {
            Task { await previewer.play(voice: voice) }
            return
        }

        let lang = voice.languageCode

        // Source language matches target — no translation needed.
        if lang == "en" {
            Task { await previewer.play(voice: voice) }
            return
        }

        if let cached = previewer.cachedTranslation(for: lang) {
            Task { await previewer.play(voice: voice, sampleText: cached) }
            return
        }

        pendingVoice = voice
        let target = Locale.Language(identifier: lang)
        if translationConfig?.target == target {
            translationConfig?.invalidate()
        } else {
            translationConfig = TranslationSession.Configuration(
                source: Self.sourceLanguage,
                target: target
            )
        }
    }

    private func runTranslation(session: TranslationSession) async {
        guard let voice = pendingVoice else { return }
        defer { pendingVoice = nil }

        let text: String
        do {
            let response = try await session.translate(AzureVoicePreviewer.defaultSampleText)
            text = response.targetText
            previewer.cacheTranslation(text, for: voice.languageCode)
        } catch {
            text = AzureVoicePreviewer.defaultSampleText
        }
        await previewer.play(voice: voice, sampleText: text)
    }
}
