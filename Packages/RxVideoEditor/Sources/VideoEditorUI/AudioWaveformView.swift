import Foundation
import SwiftUI
import VideoEditorCore

/// A compact, bottom-aligned waveform like the audio strip beneath footage.
public struct AudioWaveformView: View {
    let url: URL
    let inPoint: TimeInterval
    let duration: TimeInterval?
    var playbackRate: Double = 1
    var isReversed: Bool = false
    let volume: Float
    let currentTime: TimeInterval?
    @State private var waveform: AudioWaveform?
    @State private var isLoading = true
    @State private var waveformPath = Path()
    @State private var drawingSize = CGSize.zero

    public init(url: URL, inPoint: TimeInterval = 0, duration: TimeInterval? = nil, volume: Float = 1, currentTime: TimeInterval? = nil, playbackRate: Double = 1, isReversed: Bool = false) {
        self.url = url
        self.inPoint = inPoint
        self.duration = duration
        self.volume = volume
        self.playbackRate = playbackRate
        self.isReversed = isReversed
        self.currentTime = currentTime
    }

    public var body: some View {
        ZStack {
            WaveformDrawing(path: waveformPath).equatable()
            Canvas { context, size in
                let seconds = duration ?? waveform?.duration ?? 0
                guard seconds > 0 else { return }
                if let currentTime, currentTime.isFinite {
                    let progress = min(1, max(0, (currentTime - inPoint) / seconds))
                    // Keep the stroke visible at both the start and end of the file.
                    let x = min(max(1, size.width * progress), max(1, size.width - 1))
                    var playhead = Path()
                    playhead.move(to: CGPoint(x: x, y: 0))
                    playhead.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(playhead, with: .color(.red), lineWidth: 2)
                    var marker = Path()
                    marker.move(to: CGPoint(x: x - 4, y: 0))
                    marker.addLine(to: CGPoint(x: x + 4, y: 0))
                    marker.addLine(to: CGPoint(x: x, y: 5))
                    marker.closeSubpath()
                    context.fill(marker, with: .color(.red))
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            drawingSize = size
            rebuildPath()
        }
        .onChange(of: inPoint) { rebuildPath() }
        .onChange(of: duration) { rebuildPath() }
        .onChange(of: volume) { rebuildPath() }
        .onChange(of: playbackRate) { rebuildPath() }
        .onChange(of: isReversed) { rebuildPath() }
        .background(waveform == nil ? .clear : Color.black.opacity(0.25))
        .overlay {
            if isLoading { ProgressView().controlSize(.mini).scaleEffect(0.6) }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityLabel("Audio waveform")
        .task(id: url) {
            waveform = nil
            waveformPath = Path()
            isLoading = true
            let loaded = await AudioWaveformCache.shared.waveform(for: url)
            guard !Task.isCancelled else { return }
            waveform = loaded
            rebuildPath()
            isLoading = false
        }
    }

    /// Geometry changes only with the source, trim, gain or layout, never with
    /// playback time. Long recordings can contain 100,000 peak samples.
    private func rebuildPath() {
        var path = Path()
        defer { waveformPath = path }
        guard let waveform else { return }
        let seconds = duration.map { $0 * playbackRate } ?? waveform.duration
        let size = drawingSize
        guard seconds > 0, size.width > 0 else { return }
        let columns = max(1, Int(ceil(size.width)))
        path.move(to: CGPoint(x: 0, y: size.height))
        for column in 0..<columns {
            let sourceColumn = isReversed ? columns - column - 1 : column
            let start = inPoint + Double(sourceColumn) / Double(columns) * seconds
            let end = inPoint + Double(sourceColumn + 1) / Double(columns) * seconds
            let peak = waveform.displayPeak(from: start, to: end) * max(0, volume)
            let height = max(1, size.height * min(1, CGFloat(peak)))
            path.addLine(to: CGPoint(x: CGFloat(column), y: size.height - height))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
    }
}

/// Keep the static canvas out of playhead redraws as well as peak sampling.
private struct WaveformDrawing: View, Equatable {
    let path: Path

    var body: some View {
        Canvas { context, _ in
            context.fill(path, with: .color(.white.opacity(0.65)))
        }
    }

}

struct ClipWaveformView: View {
    let source: ClipSource
    let resolver: any MediaResolver
    let inPoint: TimeInterval
    let duration: TimeInterval
    var playbackRate: Double = 1
    var isReversed: Bool = false
    let volume: Float
    @State private var url: URL?

    var body: some View {
        // Keep a concrete view mounted while the URL is unresolved. An empty
        // Group has no child to run the task, so it can never load its audio.
        ZStack {
            Color.clear
            if let url {
                AudioWaveformView(url: url, inPoint: inPoint, duration: duration, volume: volume, playbackRate: playbackRate, isReversed: isReversed)
            }
        }
        .task(id: source) {
            url = nil
            let media = try? await resolver.resolve(source)
            guard !Task.isCancelled else { return }
            url = media?.fileURL
        }
    }
}
