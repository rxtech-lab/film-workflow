import AVFoundation
import Foundation
import Observation

@Observable
@MainActor
final class GeminiVoicePreviewer: NSObject {
    static let shared = GeminiVoicePreviewer()
    static let defaultSampleText = "Hello! This is how I sound. I can narrate your story with warmth, clarity, and a natural rhythm — shifting tone to match the mood of every scene."

    private(set) var loadingVoice: String?
    private(set) var playingVoice: String?
    private(set) var lastError: String?

    private struct AudioKey: Hashable {
        let voiceName: String
        let text: String
    }

    private var audioCache: [AudioKey: Data] = [:]
    private var player: AVAudioPlayer?
    private var delegateProxy: PlayerDelegate?

    private override init() { super.init() }

    func play(voice: GeminiVoice, sampleText: String? = nil) async {
        lastError = nil
        let name = voice.rawValue
        let text = (sampleText?.isEmpty == false ? sampleText! : Self.defaultSampleText)

        if playingVoice == name {
            stop()
            return
        }
        stop()

        let key = AudioKey(voiceName: name, text: text)
        let data: Data
        if let cached = audioCache[key] {
            data = cached
        } else {
            loadingVoice = name
            defer { if loadingVoice == name { loadingVoice = nil } }
            do {
                let config = try AppConfig.loadFromKeychain()
                guard !config.googleAIKey.isEmpty else {
                    lastError = "Add your Google AI API key in Settings."
                    return
                }
                let response = try await GeminiTTSClient.generateSample(
                    voiceName: name,
                    apiKey: config.googleAIKey,
                    text: text
                )
                data = response.audioData
                audioCache[key] = data
            } catch {
                lastError = error.localizedDescription
                return
            }
        }

        do {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            let p = try AVAudioPlayer(data: data)
            let proxy = PlayerDelegate { [weak self] in
                Task { @MainActor in self?.handleDidFinish(name: name) }
            }
            p.delegate = proxy
            self.delegateProxy = proxy
            self.player = p
            playingVoice = name
            p.play()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        player?.stop()
        player = nil
        delegateProxy = nil
        playingVoice = nil
    }

    private func handleDidFinish(name: String) {
        if playingVoice == name {
            playingVoice = nil
        }
        player = nil
        delegateProxy = nil
    }

    private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            onFinish()
        }
    }
}
