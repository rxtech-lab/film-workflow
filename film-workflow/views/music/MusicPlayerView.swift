import AVFoundation
import SwiftUI

@Observable
class AudioPlayerManager {
    private var player: AVAudioPlayer?
    private var timer: Timer?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var currentURL: URL?

    func load(url: URL) throws {
        stop()
        player = try AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        duration = player?.duration ?? 0
        currentTime = 0
        currentURL = url
    }

    func play() {
        player?.play()
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

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let player = self.player {
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    self.stopTimer()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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

struct MusicPlayerView: View {
    let url: URL
    @State private var playerManager = AudioPlayerManager()
    @State private var loadError: String?

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
        .onDisappear {
            playerManager.stop()
        }
    }
}
