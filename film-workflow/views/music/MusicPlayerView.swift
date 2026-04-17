import AVFoundation
import SwiftUI

@Observable
class AudioPlayerManager: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentURL: URL?

    func load(url: URL) throws {
        if currentURL == url, player != nil {
            return
        }
        stop()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        #endif
        let newPlayer = try AVAudioPlayer(contentsOf: url)
        newPlayer.delegate = self
        newPlayer.prepareToPlay()
        player = newPlayer
        duration = newPlayer.duration
        currentTime = 0
        currentURL = url
    }

    func play() {
        guard let player else { return }
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func toggle() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentTime = player.currentTime
        stopTimer()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        isPlaying = false
        stopTimer()
    }

    private func startTimer() {
        stopTimer()
        let newTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let player = self.player else { return }
            self.currentTime = player.currentTime
            if !player.isPlaying && self.isPlaying {
                self.isPlaying = false
                self.stopTimer()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    deinit {
        timer?.invalidate()
        player?.stop()
    }

    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

enum AudioPlayerRegistry {
    private static var managers: [URL: AudioPlayerManager] = [:]

    static func manager(for url: URL) -> AudioPlayerManager {
        if let existing = managers[url] {
            return existing
        }
        let manager = AudioPlayerManager()
        managers[url] = manager
        return manager
    }
}

struct MusicPlayerView: View {
    let url: URL
    @State private var loadError: String?

    private var playerManager: AudioPlayerManager {
        AudioPlayerRegistry.manager(for: url)
    }

    var body: some View {
        VStack(spacing: 8) {
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                HStack(spacing: 12) {
                    Button {
                        playerManager.toggle()
                    } label: {
                        Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.borderless)

                    if playerManager.isPlaying || playerManager.currentTime > 0 {
                        Button {
                            playerManager.stop()
                        } label: {
                            Image(systemName: "stop.fill")
                                .font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }

                    Text(playerManager.formattedCurrentTime)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 35, alignment: .trailing)

                    Slider(
                        value: Binding(
                            get: { playerManager.currentTime },
                            set: { playerManager.seek(to: $0) }
                        ),
                        in: 0...max(playerManager.duration, 0.01)
                    )

                    Text(playerManager.formattedDuration)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 35, alignment: .leading)
                }
            }
        }
        .onAppear {
            do {
                try playerManager.load(url: url)
            } catch {
                loadError = "Failed to load audio: \(error.localizedDescription)"
            }
        }
        .onChange(of: url) { _, newURL in
            do {
                try playerManager.load(url: newURL)
            } catch {
                loadError = "Failed to load audio: \(error.localizedDescription)"
            }
        }
    }
}
