import AVFoundation
import AppKit
import OSLog
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
                if let url = cell.mediaURL {
                    FootagePlaybackWaveform(url: url, player: player)
                        .frame(height: 64)
                        .padding(.horizontal, 24)
                }
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

                FootagePlaybackPosition(player: player)

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
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 260, alignment: .leading)
            .disabled(versions.count < 2)
            .help("Choose footage version")
            .accessibilityLabel("Footage version")
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
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

/// Only these small subviews observe the 30 Hz playback position. Keeping the
/// read out of FootageViewer avoids rebuilding the stage and version controls.
private struct FootagePlaybackWaveform: View {
    let url: URL
    let player: FootagePlayer

    var body: some View {
        AudioWaveformView(url: url, currentTime: player.currentTime)
    }
}

private struct FootagePlaybackPosition: View {
    let player: FootagePlayer

    var body: some View {
        HStack(spacing: 12) {
            Text(DurationLabel.precise(player.currentTime))
                .font(.system(.callout, design: .monospaced))
                .frame(width: 72, alignment: .leading)

            AudioLevelMeterView(player: player.player)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.scrub(to: $0) }),
                in: 0...max(0.1, player.duration)
            ) { editing in
                if !editing { player.endScrub() }
            }
            .controlSize(.small)
            .disabled(player.duration <= 0)
        }
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
    @ObservationIgnored private let log = Logger(subsystem: "com.rxlab.film-workflow", category: "FootagePlayback")
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var lastTimeCallback: ContinuousClock.Instant?
    @ObservationIgnored private var callbackCount = 0
    @ObservationIgnored private var suppressedCallbackCount = 0
    @ObservationIgnored private var isScrubbing = false

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastTimeCallback = .now
                self.callbackCount += 1
                guard self.isPlaying else {
                    self.suppressedCallbackCount += 1
                    return
                }
                self.currentTime = max(0, CMTimeGetSeconds(time))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.log.info("item-ended uiTime=\(self.currentTime) duration=\(self.duration)")
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    func load(_ cell: FootageCell) async {
        unload()
        guard cell.kind == .video || cell.kind == .audio || cell.kind == .remotion, let url = cell.mediaURL else { return }
        log.info("load kind=\(String(describing: cell.kind), privacy: .public)")
        startDiagnostics()
        duration = cell.duration ?? 0
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        if let natural = await MediaDurationCache.duration(of: url) { duration = natural }
    }

    func unload() {
        log.info("unload uiTime=\(self.currentTime)")
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
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
        log.info("play uiTime=\(self.currentTime) actualTime=\(self.player.currentTime().seconds)")
        player.play()
        isPlaying = true
    }

    func pause() {
        log.info("pause scrubbing=\(self.isScrubbing) uiTime=\(self.currentTime)")
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
        if !isScrubbing {
            log.info("scrub-begin wasPlaying=\(self.isPlaying) target=\(time)")
            isScrubbing = true
        }
        if isPlaying { resumeAfterScrub = true; pause() }
        seek(to: time)
    }

    func endScrub() {
        log.info("scrub-end resume=\(self.resumeAfterScrub) uiTime=\(self.currentTime)")
        isScrubbing = false
        if resumeAfterScrub { resumeAfterScrub = false; play() }
    }

    /// One heartbeat per second while active; never emit logs on every frame.
    /// ContinuousClock exposes main-actor stalls even when the audio thread keeps running.
    private func startDiagnostics() {
        lastTimeCallback = nil
        callbackCount = 0
        suppressedCallbackCount = 0
        diagnosticsTask = Task { @MainActor [weak self] in
            var previous: ContinuousClock.Instant = .now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                guard let self else { break }
                let now = ContinuousClock.now
                let elapsed = Self.seconds(previous.duration(to: now))
                previous = now
                let actual = self.player.currentTime().seconds
                let rate = self.player.rate
                let active = self.isPlaying || rate != 0
                let callbacks = self.callbackCount
                let suppressed = self.suppressedCallbackCount
                self.callbackCount = 0
                self.suppressedCallbackCount = 0
                guard active else { continue }
                let age = self.lastTimeCallback.map { Self.seconds($0.duration(to: now)) } ?? -1
                let lag = actual - self.currentTime
                let status = self.player.timeControlStatus.rawValue
                let itemStatus = self.player.currentItem?.status.rawValue ?? -1
                let waiting = self.player.reasonForWaitingToPlay?.rawValue ?? "none"
                self.log.debug("heartbeat actual=\(actual) ui=\(self.currentTime) rate=\(rate) isPlaying=\(self.isPlaying) status=\(status) itemStatus=\(itemStatus) waiting=\(waiting, privacy: .public) callbacks=\(callbacks) suppressed=\(suppressed) callbackAge=\(age) mainInterval=\(elapsed) scrubbing=\(self.isScrubbing)")
                if elapsed > 1.5 || (rate > 0 && (abs(lag) > 0.5 || !self.isPlaying || callbacks == 0)) {
                    self.log.warning("visual-stall actual=\(actual) ui=\(self.currentTime) lag=\(lag) rate=\(rate) isPlaying=\(self.isPlaying) callbacks=\(callbacks) suppressed=\(suppressed) callbackAge=\(age) mainInterval=\(elapsed)")
                }
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
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
