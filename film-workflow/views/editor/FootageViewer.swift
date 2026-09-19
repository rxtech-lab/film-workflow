import AVFoundation
import AppKit
import OSLog
import SwiftUI
import SwiftData
import VideoEditorCore
import VideoEditorUI

/// Plays one piece of footage — a generated take or an imported file — with
/// its own transport, so previewing never touches the sequence player.
struct FootageViewer: View {
    let cell: FootageCell
    let name: String
    let versions: [FootageCell]
    let onSelectVersion: (UUID) -> Void
    /// Where the browser is skimming this footage, as a share of its length.
    /// Nil when the pointer is not over its cell.
    var skimFraction: Double? = nil

    var player: FootagePlayer
    var document: ProjectDocument? = nil
    @State private var fitsViewer = true
    @State private var previewRevision = 0
    @State private var lyricsRequest: MusicLyricsRequest?
    private struct LoadRequest: Hashable { let cell: FootageCell; let revision: Int }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                Color.black
                stage
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("viewer.stage")
            transport
        }
        .task(id: LoadRequest(cell: cell, revision: previewRevision)) { await player.load(cell, document: document) }
        .onChange(of: skimFraction, initial: true) { _, fraction in
            if let fraction { player.skim(toFraction: fraction) } else { player.endSkim() }
        }
        .onDisappear { player.unload() }
        .contextMenu {
            MusicLyricsContextMenu(sourceID: cell.drag.source.id) {
                player.pause()
                lyricsRequest = $0
            }
        }
        .musicLyricsHost($lyricsRequest)
        .onReceive(NotificationCenter.default.publisher(for: .remotionPreviewChanged)) { note in
            if let directory = note.userInfo?["directory"] as? URL, directory.standardizedFileURL == cell.previewDirectory {
                previewRevision += 1
            }
        }
    }

    @ViewBuilder
    private var stage: some View {
        // One structural position for the layered preview across every kind.
        // Two sibling branches sharing one controller let SwiftUI order a swap
        // as appear-then-disappear, which used to leave the controller marked
        // invisible and buffering forever.
        if cell.kind == .remotion || cell.kind == .captions || (cell.kind == .video && player.usesGeneratedPreview) {
            TimelineLayeredPreviewView(controller: player.generatedPreview) { AnyView(RemotionPlayerWebView(playback: $0)) }
        } else {
            switch cell.kind {
            case .remotion, .captions:
                EmptyView()
            case .video:
                FootagePlayerLayerView(player: player.player, fitsViewer: fitsViewer)
            case .image:
                if let url = cell.mediaURL, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: fitsViewer ? .fit : .fill).clipped()
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
                    MusicLyricsPlayback(sourceID: cell.drag.source.id, player: player)
                        .id(cell.drag.source.id)
                }
            // A zoom belongs to the recording it zooms; it is never library footage.
            case .zoom:
                unavailable("Nothing to Play", symbol: "plus.magnifyingglass")
            }
        }
    }

    private func unavailable(_ title: LocalizedStringKey, symbol: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol).foregroundStyle(.white)
    }

    private var isPlayable: Bool { cell.previewSource?.canScrub == true }

    private var header: some View {
        HStack(spacing: 10) {
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(detail)
            Spacer(minLength: 0)
            Label(name, systemImage: cell.kind.symbolName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 0)
            Menu {
                Picker("Version", selection: Binding(get: { cell.id }, set: onSelectVersion)) {
                    ForEach(versions) { version in Text(version.title).tag(version.id) }
                }
            } label: {
                Text(cell.title == name ? String(localized: "Original") : cell.title)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: 150)
            .disabled(versions.count < 2)
            .help("Choose footage version")
            .accessibilityLabel("Footage version")
            .accessibilityIdentifier("viewer.version")
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.header")
    }

    private var transport: some View {
        HStack(spacing: 6) {
            Menu {
                Toggle("Fit to Viewer", isOn: $fitsViewer)
                if cell.kind == .captions || cell.kind == .remotion {
                    Button("Reload Preview") { previewRevision += 1 }
                }
                if isPlayable {
                    Toggle("Mute", isOn: Binding(get: { player.player.isMuted }, set: { player.player.isMuted = $0 }))
                    Divider()
                    Button("Go to Start") { player.pause(); player.seek(to: 0) }
                    Button("Go to End") { player.pause(); player.seek(to: player.duration) }
                }
            } label: { Image(systemName: "slider.horizontal.3") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Viewer tools")
            .accessibilityLabel("Viewer tools")
            .accessibilityIdentifier("viewer.tools")
            Spacer(minLength: 0)
            if isPlayable {
                Button { player.pause(); player.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                    .help("Previous frame")
                    .accessibilityIdentifier("viewer.previous-frame")
                Button { player.togglePlay() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(player.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("viewer.play")
                FootagePlaybackPosition(player: player)
                Button { player.pause(); player.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                    .help("Next frame")
            } else {
                Text("Still").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isPlayable { AudioLevelMeterView(player: player.player) }
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Toggle full screen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .frame(height: 40)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("viewer.transport")
    }

    /// Length and size of what is on screen.
    private var detail: String {
        var parts: [String] = []
        let seconds = player.duration > 0 ? player.duration : (cell.duration ?? 0)
        if seconds > 0 { parts.append(DurationLabel.short(seconds)) }
        if cell.kind == .video, player.frameRate > 0 { parts.append("\(player.frameRate.formatted(.number.precision(.fractionLength(0...2))))p") }
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
        Text(Timecode.string(seconds: player.currentTime, fps: max(1, Int(player.frameRate.rounded()))))
            .font(.system(size: 17, weight: .light, design: .monospaced))
            .monospacedDigit()
            .fixedSize()
            .accessibilityIdentifier("viewer.timecode")
    }
}

/// An `AVPlayer` for one file: time, length and play state as observable values.
@MainActor
@Observable
final class FootagePlayer {
    private let mediaPlayer = AVPlayer()
    let generatedTransport: TimelinePlayerController
    let generatedPreview: TimelinePreviewController
    private(set) var usesGeneratedPreview = false
    private var nativeCurrentTime: TimeInterval = 0
    private var nativeDuration: TimeInterval = 0
    private var nativeIsPlaying = false
    var player: AVPlayer { usesGeneratedPreview ? generatedTransport.player : mediaPlayer }
    var currentTime: TimeInterval { usesGeneratedPreview ? generatedTransport.currentTime : nativeCurrentTime }
    var duration: TimeInterval { usesGeneratedPreview ? max(nativeDuration, generatedTransport.duration) : nativeDuration }
    var isPlaying: Bool { usesGeneratedPreview ? generatedTransport.isPlaying : nativeIsPlaying }
    private(set) var loadedCellID: UUID?
    private(set) var frameRate: Double = 30
    @ObservationIgnored private var pendingPosition: (cellID: UUID, fraction: Double)?
    @ObservationIgnored private var loadGeneration = UUID()
    var playbackFraction: Double { duration > 0 ? (restingTime ?? currentTime) / duration : 0 }

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var resumeAfterScrub = false
    /// Where playback sat when skimming began, so the frame comes back once
    /// the pointer leaves the footage.
    private var restingTime: TimeInterval?
    /// The skimmed position as a share of the length. Kept across a reload
    /// so a take that is still opening lands on the right frame.
    @ObservationIgnored private var skimFraction: Double?
    @ObservationIgnored private let log = Logger(subsystem: "com.rxlab.film-workflow", category: "FootagePlayback")
    @ObservationIgnored private var diagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var lastTimeCallback: ContinuousClock.Instant?
    @ObservationIgnored private var callbackCount = 0
    @ObservationIgnored private var suppressedCallbackCount = 0
    @ObservationIgnored private var isScrubbing = false

    init() {
        let transport = TimelinePlayerController()
        generatedTransport = transport
        generatedPreview = TimelinePreviewController(transport: transport)
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
                self.nativeCurrentTime = max(0, CMTimeGetSeconds(time))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let ended = (note.object as AnyObject?).map(ObjectIdentifier.init)
            Task { @MainActor [weak self] in
                guard let self, let current = self.player.currentItem, ended == ObjectIdentifier(current) else { return }
                self.log.info("item-ended uiTime=\(self.currentTime) duration=\(self.duration)")
                self.nativeIsPlaying = false
                self.nativeCurrentTime = self.duration
            }
        }
    }

    func load(_ cell: FootageCell, document: ProjectDocument? = nil) async {
        unload()
        let generation = loadGeneration
        loadedCellID = cell.id
        nativeDuration = cell.duration ?? 0
        if let document, let (prefix, id) = DocumentMediaResolver.parse(cell.drag.source.id), prefix == .screenRecording,
           let take = try? RecordingTimelineService.take(id: id, context: document.container.mainContext), let timeline = try? RecordingTimelineService.previewTimeline(take) {
            usesGeneratedPreview = true; frameRate = Double(timeline.fps)
            generatedPreview.load(timeline, resolver: LibraryFootagePreviewResolver(document: document, width: timeline.width, height: timeline.height, fps: timeline.fps, captionAudio: nil))
            applyRequestedPosition(for: cell.id); return
        }
        if let document, cell.kind == .remotion || cell.kind == .captions {
            usesGeneratedPreview = true
            frameRate = Double(max(1, cell.previewFPS))
            let width = cell.drag.naturalWidth ?? 1920
            let height = cell.drag.naturalHeight ?? 1080
            let clip = Clip(id: cell.id, source: cell.drag.source, start: 0, duration: max(0.1, duration),
                            sourceDuration: duration, text: cell.captionStyle)
            var tracks = [Track(kind: cell.kind == .captions ? .caption : .video, name: cell.title, clips: [clip])]
            if cell.captionAudioURL != nil {
                let source = ClipSource(id: "library-caption-audio", kind: .audio, displayName: cell.title)
                tracks.append(Track(kind: .audio, name: "Source audio", clips: [Clip(source: source, start: 0, duration: max(0.1, duration))]))
            }
            let timeline = Timeline(width: width, height: height, fps: max(1, Int(frameRate)), tracks: tracks)
            generatedPreview.load(timeline, resolver: LibraryFootagePreviewResolver(document: document, width: width, height: height,
                                                                                   fps: max(1, Int(frameRate)), captionAudio: cell.captionAudioURL))
            applyRequestedPosition(for: cell.id)
            return
        }
        guard cell.kind == .video || cell.kind == .audio || cell.kind == .remotion, let url = cell.mediaURL else { return }
        log.info("load kind=\(String(describing: cell.kind), privacy: .public)")
        startDiagnostics()
        nativeDuration = cell.duration ?? 0
        let asset = AVURLAsset(url: url)
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        let natural = await MediaDurationCache.duration(of: url)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        if let natural { nativeDuration = natural }
        applyRequestedPosition(for: cell.id)
        if cell.kind == .video || cell.kind == .remotion,
           let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 0,
           !Task.isCancelled, loadGeneration == generation {
            frameRate = Double(rate)
        }
    }

    private func applyRequestedPosition(for cellID: UUID) {
        if let pending = pendingPosition, pending.cellID == cellID {
            pendingPosition = nil
            seek(to: pending.fraction * duration)
        }
        if let skimFraction { skim(toFraction: skimFraction) }
    }

    /// A click commits the skimmed frame, including when its media is still opening.
    func commitPosition(fraction: Double, cellID: UUID) {
        guard fraction.isFinite else { return }
        let clamped = min(max(0, fraction), 1)
        skimFraction = nil
        restingTime = nil
        pause()
        if loadedCellID == cellID, duration > 0 {
            pendingPosition = nil
            seek(to: clamped * duration)
        } else {
            pendingPosition = (cellID, clamped)
        }
    }

    func step(frames: Int) {
        seek(to: currentTime + Double(frames) / max(1, frameRate))
    }

    func unload() {
        generatedPreview.unload()
        generatedTransport.unload()
        usesGeneratedPreview = false
        loadGeneration = UUID()
        loadedCellID = nil
        frameRate = 30
        resumeAfterScrub = false
        isScrubbing = false
        log.info("unload uiTime=\(self.currentTime)")
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        nativeIsPlaying = false
        restingTime = nil
        nativeCurrentTime = 0
        nativeDuration = 0
    }

    func play() {
        restingTime = nil
        skimFraction = nil
        if usesGeneratedPreview { generatedTransport.play(); return }
        guard player.currentItem != nil else { return }
        if duration > 0, currentTime >= duration - 0.05 {
            nativeCurrentTime = 0
            player.seek(to: .zero)
        }
        log.info("play uiTime=\(self.currentTime) actualTime=\(self.player.currentTime().seconds)")
        player.play()
        nativeIsPlaying = true
    }

    func pause() {
        if usesGeneratedPreview { generatedTransport.pause(); return }
        log.info("pause scrubbing=\(self.isScrubbing) uiTime=\(self.currentTime)")
        player.pause()
        nativeIsPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if usesGeneratedPreview { generatedTransport.seek(to: min(max(0, time), duration)); return }
        nativeCurrentTime = min(max(0, time), max(0, duration))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Scrubbing pauses playback and resume when the thumb is released.
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

    /// Shows the frame at `fraction` (0...1) of the length without losing
    /// the position playback had. Ignored while playing, so a pass of the
    /// pointer never interrupts a take that is being listened to.
    func skim(toFraction fraction: Double) {
        guard fraction.isFinite else { return }
        skimFraction = min(max(0, fraction), 1)
        guard (usesGeneratedPreview || player.currentItem != nil), duration > 0, !isPlaying else { return }
        if restingTime == nil { restingTime = currentTime }
        seek(to: skimFraction! * duration)
    }

    /// Puts playback back where it was before skimming.
    func endSkim() {
        skimFraction = nil
        guard let resting = restingTime else { return }
        restingTime = nil
        seek(to: resting)
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
    var fitsViewer = true

    func makeNSView(context: Context) -> FootagePlayerHostView {
        let view = FootagePlayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: FootagePlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player { nsView.playerLayer.player = player }
        nsView.playerLayer.videoGravity = fitsViewer ? .resizeAspect : .resizeAspectFill
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
