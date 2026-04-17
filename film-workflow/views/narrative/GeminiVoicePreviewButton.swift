import SwiftUI

struct GeminiVoicePreviewButton: View {
    let voice: GeminiVoice

    @State private var previewer = GeminiVoicePreviewer.shared

    var body: some View {
        let name = voice.rawValue
        let isLoading = previewer.loadingVoice == name
        let isPlaying = previewer.playingVoice == name

        Button {
            Task { await previewer.play(voice: voice) }
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
        .disabled(isLoading)
        .help(isPlaying ? "Stop" : "Preview voice")
    }
}
