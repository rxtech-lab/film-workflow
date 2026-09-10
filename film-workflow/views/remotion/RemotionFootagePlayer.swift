import SwiftUI
import VideoEditorCore
import VideoEditorUI

struct RemotionViewer: View {
    let project: RemotionProject
    let document: ProjectDocument
    @State private var studio = false
    @State private var retry = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                Picker("Remotion viewer", selection: $studio) {
                    Text("Player").tag(false)
                    Text("Studio").tag(true)
                }.pickerStyle(.segmented).frame(width: 160)
                Button { retry += 1 } label: { Image(systemName: "arrow.clockwise") }
                    .help("Reload preview")
            }.padding(10).background(.bar)
            if studio { RemotionStudioViewer(project: project).id(retry) }
            else { RemotionFootagePlayer(project: project, document: document).id(retry) }
        }
    }
}

@MainActor @Observable
private final class RemotionFootagePlayback {
    let transport: TimelinePlayerController
    let preview: TimelinePreviewController
    init() {
        transport = TimelinePlayerController()
        preview = TimelinePreviewController(transport: transport)
    }
}

private struct RemotionFootagePlayer: View {
    let project: RemotionProject
    let document: ProjectDocument
    @State private var playback = RemotionFootagePlayback()
    @State private var resumeAfterScrub = false
    @State private var revision = 0

    private var settings: String { "\(project.id):\(project.durationSeconds):\(project.compositionWidth):\(project.compositionHeight):\(project.compositionFps)" }

    var body: some View {
        VStack(spacing: 0) {
            SequenceViewerView(controller: playback.transport, fps: project.compositionFps, stage: AnyView(
                TimelineLayeredPreviewView(controller: playback.preview) { AnyView(RemotionPlayerWebView(playback: $0)) }
            ))
            Slider(value: Binding(get: { min(playback.transport.currentTime, project.durationSeconds) },
                                  set: { playback.transport.seek(to: $0) }), in: 0...max(0.1, project.durationSeconds)) { editing in
                if editing { resumeAfterScrub = playback.transport.isPlaying; playback.transport.pause() }
                else if resumeAfterScrub { playback.transport.play(); resumeAfterScrub = false }
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
        }
        .task(id: settings + ":\(revision)") {
            let clip = Clip(id: project.id, source: project.clipSource, start: 0, duration: max(0.1, project.durationSeconds), sourceDuration: project.durationSeconds)
            let timeline = Timeline(width: project.compositionWidth, height: project.compositionHeight, fps: project.compositionFps,
                                    tracks: [Track(kind: .video, name: "Remotion", clips: [clip])])
            playback.preview.load(timeline, resolver: DocumentPreviewMediaResolver(document: document,
                width: project.compositionWidth, height: project.compositionHeight, fps: project.compositionFps))
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { note in
            if note.userInfo?["directory"] as? URL == project.projectDir.standardizedFileURL { revision += 1 }
        }
        .onDisappear { playback.preview.unload(); playback.transport.unload() }
    }
}
