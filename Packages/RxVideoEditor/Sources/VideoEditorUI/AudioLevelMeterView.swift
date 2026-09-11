import AVFoundation
import Foundation
import SwiftUI
import VideoEditorCore

/// Stereo sample peaks for the source currently playing in this viewer.
public struct AudioLevelMeterView: View {
    let player: AVPlayer
    @State private var level = StereoAudioLevel.silence

    public init(player: AVPlayer) { self.player = player }

    public var body: some View {
        HStack(spacing: 4) {
            channel(peak: level.left)
            channel(peak: level.right)
        }
        .frame(width: 18, height: 24)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stereo audio levels")
        .accessibilityValue("Left \(decibels(level.left)), right \(decibels(level.right))")
        .help("Audio levels — left: \(decibels(level.left)), right: \(decibels(level.right))")
        .task {
            let reader = AudioLevelReader()
            var itemID: ObjectIdentifier?
            var mixID: ObjectIdentifier?
            while !Task.isCancelled {
                let item = player.currentItem
                let nextID = item.map(ObjectIdentifier.init)
                let mix = item?.audioMix
                let nextMixID = mix.map(ObjectIdentifier.init)
                if nextID != itemID || nextMixID != mixID {
                    itemID = nextID
                    mixID = nextMixID
                    level = .silence
                    await reader.setSource(item.map { AudioLevelSource(asset: $0.asset, mix: mix) })
                }
                if player.timeControlStatus == .playing, !player.isMuted {
                    let measured = await reader.level(at: CMTimeGetSeconds(player.currentTime()))
                    guard !Task.isCancelled else { break }
                    if player.currentItem === item, player.timeControlStatus == .playing {
                        let gain = player.isMuted ? 0 : player.volume
                        level = StereoAudioLevel(left: measured.left * gain, right: measured.right * gain)
                    } else {
                        level = .silence
                    }
                } else {
                    level = .silence
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            await reader.setSource(nil)
        }
    }

    private func channel(peak: Float) -> some View {
        VStack(spacing: 2) {
            Rectangle()
                .fill(peak >= 1 ? Color.red : Color.primary.opacity(0.12))
                .frame(height: 2)
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    Color.primary.opacity(0.10)
                    Rectangle()
                        .fill(peak >= 0.708 ? Color.red : peak >= 0.251 ? Color.yellow : Color.green)
                        .frame(height: geometry.size.height * fraction(peak))
                }
            }
        }
        .frame(width: 7)
    }

    private func fraction(_ peak: Float) -> Double {
        guard peak > 0 else { return 0 }
        return min(1, max(0, (20 * log10(Double(peak)) + 60) / 60))
    }

    private func decibels(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f dBFS", 20 * log10(Double(peak))) : "silent"
    }
}
