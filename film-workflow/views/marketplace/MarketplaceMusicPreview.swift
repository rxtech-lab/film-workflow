import AVFoundation
import SwiftUI
import VideoEditorUI

@MainActor @Observable
final class MarketplaceAudioPlayer {
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var captionOffset: Double = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var status: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var failureObserver: NSObjectProtocol?

    init() {
        player.actionAtItemEnd = .pause
        failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let item = note.object as? AVPlayerItem, self.player.currentItem === item else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                self.fail(error?.localizedDescription ?? String(localized: "Couldn’t play this preview. Try again."))
            }
        }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                if time.seconds.isFinite { self.currentTime = max(0, time.seconds) }
                if let seconds = self.player.currentItem?.duration.seconds, seconds.isFinite { self.duration = max(0, seconds) }
                self.isPlaying = self.player.timeControlStatus == .playing
                if self.isPlaying { self.isLoading = false; self.timeoutTask?.cancel() }
            }
        }
    }

    func toggle(resolve: @escaping @MainActor () async throws -> (url: URL, start: Double)) {
        if player.currentItem != nil {
            if player.timeControlStatus != .paused {
                player.pause(); isPlaying = false
            } else {
                if duration > 0, currentTime >= duration - 0.05 { seek(to: 0) }
                player.play()
            }
            return
        }
        guard !isLoading else { return }
        error = nil; isLoading = true
        let token = UUID(); generation = token
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(20)) } catch { return }
            guard let self, self.generation == token, self.isLoading else { return }
            self.fail(String(localized: "The preview took too long to load. Try again."))
        }
        loadTask = Task { [weak self] in
            do {
                let source = try await resolve()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.captionOffset = source.start
                let item = AVPlayerItem(url: source.url)
                self.status = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    guard item.status == .failed else { return }
                    Task { @MainActor [weak self] in
                        guard let self, self.player.currentItem === item else { return }
                        self.fail(item.error?.localizedDescription ?? String(localized: "Couldn’t play this preview. Try again."))
                    }
                }
                self.player.replaceCurrentItem(with: item)
                self.player.isMuted = false
                self.player.play()
            } catch is CancellationError {
            } catch {
                guard let self, self.generation == token else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    func seek(to seconds: Double) {
        currentTime = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func fail(_ message: String) { unload(); error = message }

    func unload() {
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        status?.invalidate(); status = nil
        player.pause(); player.replaceCurrentItem(with: nil)
        currentTime = 0; duration = 0; captionOffset = 0
        isPlaying = false; isLoading = false
        error = nil
    }

    isolated deinit {
        loadTask?.cancel(); timeoutTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        player.pause()
    }
}

/// Audio keeps its cover visible and draws timed lyrics above its transport.
struct MarketplaceMusicPreview: View {
    let item: MarketplaceItem
    var canPlay = true
    let resolveSource: @MainActor () async throws -> (url: URL, start: Double)
    @State var playback = MarketplaceAudioPlayer()
    @State private var language: String?

    private var tracks: [MarketplaceLyricTrack] { item.metadata.lyricTracks ?? [] }
    private var selectedTrack: MarketplaceLyricTrack? {
        guard language != "off" else { return nil }
        return tracks.first { $0.id == language } ?? tracks.first
    }

    var body: some View {
        ZStack {
            MarketplacePreviewImage(url: item.previewImageUrl, kind: item.kind)
            VStack(spacing: 12) {
                Spacer(minLength: 42)
                if !tracks.isEmpty {
                    Text(selectedTrack?.text(at: playback.currentTime + playback.captionOffset) ?? "")
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 3)
                        .padding(12)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("marketplace-music-caption")
                }
                VStack(spacing: 8) {
                    if !tracks.isEmpty {
                        Picker("Lyrics", selection: Binding(get: { language ?? tracks.first?.id ?? "off" }, set: { language = $0 })) {
                            Text("Off").tag("off")
                            ForEach(tracks) { track in Text(track.displayName).tag(track.id) }
                        }
                        .accessibilityIdentifier("marketplace-music-language")
                    }
                    HStack(spacing: 12) {
                        Button { playback.toggle(resolve: resolveSource) } label: {
                            if playback.isLoading { ProgressView().controlSize(.small).frame(width: 20) }
                            else { Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill").frame(width: 20) }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canPlay || playback.isLoading)
                        .accessibilityLabel(playback.isPlaying ? "Pause preview" : "Play preview")
                        .accessibilityIdentifier("marketplace-music-play")
                        Text(DurationLabel.short(playback.currentTime)).monospacedDigit()
                            .accessibilityValue(String(playback.currentTime))
                            .accessibilityIdentifier("marketplace-music-time")
                        Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }), in: 0...max(playback.duration, 0.01))
                            .disabled(playback.duration <= 0)
                            .accessibilityLabel("Playback position")
                            .accessibilityIdentifier("marketplace-music-seek")
                        Text(DurationLabel.short(playback.duration)).monospacedDigit()
                    }
                    if let error = playback.error {
                        Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("marketplace-preview-error")
                    } else if !canPlay {
                        Text("No audio preview available").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(16)
        }
        .onChange(of: item.id) { playback.unload(); language = nil }
        .onChange(of: item.previewVideoUrl) { playback.unload() }
        .onDisappear { playback.unload() }
    }
}
