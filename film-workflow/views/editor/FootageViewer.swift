import AVFoundation
import AppKit
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// Plays one piece of footage — a generated take or an imported file — with
/// its own transport, so previewing never touches the sequence player.
struct FootageViewer: View {
    let cell: FootageCell
    let name: String
    let versions: [FootageCell]
    let onSelectVersion: (UUID) -> Void

    @State private var player = FootagePlayer()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                stage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            transport
        }
        .task(id: cell.id) { await player.load(cell) }
        .onDisappear { player.unload() }
    }

    @ViewBuilder
    private var stage: some View {
        switch cell.kind {
        case .video, .remotion:
            FootagePlayerLayerView(player: player.player)
        case .image:
            if let url = cell.mediaURL, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).padding(12)
            } else {
                unavailable("Image Unavailable", symbol: "photo")
            }
        case .audio:
            VStack(spacing: 14) {
                Image(systemName: "waveform")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white.opacity(player.isPlaying ? 0.9 : 0.5))
                    .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                Text(name).font(.headline).foregroundStyle(.white)
                Text(cell.title).font(.callout).foregroundStyle(.white.opacity(0.6))
            }
        case .captions:
            unavailable("No Preview", symbol: "captions.bubble")
        }
    }

    private func unavailable(_ title: LocalizedStringKey, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol).foregroundStyle(.white)
    }

    private var isPlayable: Bool { cell.kind == .video || cell.kind == .audio || cell.kind == .remotion }

    private var transport: some View {
        HStack(spacing: 12) {
            if isPlayable {
                Button { player.pause(); player.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to start")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")
                Button { player.pause(); player.seek(to: player.duration) } label: { Image(systemName: "forward.end.fill") }
                    .help("Go to end")

                Text(DurationLabel.precise(player.currentTime))
                    .font(.system(.callout, design: .monospaced))
                    .frame(width: 72, alignment: .leading)

                Slider(
                    value: Binding(get: { player.currentTime }, set: { player.scrub(to: $0) }),
                    in: 0...max(0.1, player.duration)
                ) { editing in
                    if !editing { player.endScrub() }
                }
                .controlSize(.small)
                .disabled(player.duration <= 0)

                Text(DurationLabel.precise(player.duration))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .trailing)
            } else {
                Image(systemName: cell.kind == .image ? "photo" : "captions.bubble").foregroundStyle(.secondary)
                Text(cell.kind == .image ? "Still" : "Captions").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Divider().frame(height: 16)
            Menu {
                Picker("Version", selection: Binding(
                    get: { cell.id },
                    set: { onSelectVersion($0) }
                )) {
                    ForEach(versions) { version in
                        Text(version.title).tag(version.id)
                    }
                }
            } label: {
                Text(cell.title)
            }
            .fixedSize()
            .disabled(versions.count < 2)
            .help("Choose footage version")
            .accessibilityLabel("Footage version")
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    /// Length and size of what is on screen.
    private var detail: String {
        var parts: [String] = []
        let seconds = player.duration > 0 ? player.duration : (cell.duration ?? 0)
        if seconds > 0 { parts.append(DurationLabel.short(seconds)) }
        if let w = cell.drag.naturalWidth, let h = cell.drag.naturalHeight, w > 0, h > 0 { parts.append("\(w)×\(h)") }
        if cell.kind == .image { parts.append(String(localized: "Holds \(Int(FootageDragItem.defaultStillDuration)) s on the timeline")) }
        return parts.joined(separator: " · ")
    }
}

/// An `AVPlayer` for one file: time, length and play state as observable values.
@MainActor
@Observable
final class FootagePlayer {
    let player = AVPlayer()
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var isPlaying = false

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var resumeAfterScrub = false

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.currentTime = max(0, CMTimeGetSeconds(time))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    func load(_ cell: FootageCell) async {
        unload()
        guard cell.kind == .video || cell.kind == .audio || cell.kind == .remotion, let url = cell.mediaURL else { return }
        duration = cell.duration ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if let natural = await MediaDurationCache.duration(of: url) { duration = natural }
    }

    func unload() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func play() {
        guard player.currentItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            currentTime = 0
            player.seek(to: .zero)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        currentTime = min(max(0, time), max(0, duration))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Slider drags pause playback and resume when the thumb is released.
    func scrub(to time: TimeInterval) {
        if isPlaying { resumeAfterScrub = true; pause() }
        seek(to: time)
    }

    func endScrub() {
        if resumeAfterScrub { resumeAfterScrub = false; play() }
    }
}

/// Hosts an `AVPlayerLayer` without the system controls.
private struct FootagePlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> FootagePlayerHostView {
        let view = FootagePlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: FootagePlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
    }
}

private final class FootagePlayerHostView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
    }

    required init?(coder: NSCoder) { nil }
}
