import AppKit
import AVFoundation
import SwiftUI
import VideoEditorCore
import VideoEditorUI

/// A single continuous time axis, folded into rows without restarting time.
struct FilmstripLayout {
    static let height: CGFloat = 64
    static let posterWidth = height * 16 / 9
    static let pointsPerSecond: CGFloat = 8

    let width: CGFloat
    let length: CGFloat
    var rowCount: Int { max(1, Int(ceil(length / width))) }

    init(duration: TimeInterval?, availableWidth: CGFloat, isTemporal: Bool) {
        width = max(1, availableWidth)
        let seconds = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 0
        length = isTemporal ? max(Self.posterWidth, seconds * Self.pointsPerSecond) : min(width, Self.posterWidth)
    }

    func rowWidth(_ row: Int) -> CGFloat { min(width, max(0, length - CGFloat(row) * width)) }
    func fraction(row: Int, x: CGFloat) -> Double {
        min(1, max(0, (CGFloat(row) * width + min(max(0, x), rowWidth(row))) / length))
    }
    func position(fraction: Double, row: Int) -> CGFloat? {
        let position = CGFloat(min(1, max(0, fraction))) * length - CGFloat(row) * width
        guard position >= 0, position < rowWidth(row) || (row == rowCount - 1 && position <= rowWidth(row)) else { return nil }
        return min(max(1, position), max(1, rowWidth(row) - 1))
    }
}

/// Each visible row decodes only its own frames. Long footage continues on
/// subsequent rows, and the same mapping drives hover, swipes and playback.
struct FootageFilmstrip: View {
    let cell: FootageCell
    let duration: TimeInterval?
    let isSelected: Bool
    var player: FootagePlayer?
    var onSkim: (Double?) -> Void = { _ in }
    var onSeek: (Double) -> Void = { _ in }

    @State private var availableWidth: CGFloat = 300
    @State private var skimFraction: Double?

    private var temporal: Bool { cell.kind == .video || cell.kind == .audio || cell.kind == .remotion }
    private var skimmable: Bool { temporal && cell.mediaURL != nil && cell.kind != .remotion }

    var body: some View {
        let layout = FilmstripLayout(duration: duration, availableWidth: availableWidth, isTemporal: temporal)
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(0..<layout.rowCount, id: \.self) { row in
                strip(row: row, layout: layout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { availableWidth = max(1, $0) }
        .onChange(of: cell.id) { _, _ in endSkim() }
        .onDisappear { if skimFraction != nil { endSkim() } }
    }

    private func strip(row: Int, layout: FilmstripLayout) -> some View {
        FilmstripFrames(cell: cell, duration: duration, startFraction: layout.fraction(row: row, x: 0),
                        endFraction: layout.fraction(row: row, x: layout.rowWidth(row)), width: layout.rowWidth(row))
            .frame(width: layout.rowWidth(row), height: FilmstripLayout.height)
            .clipped()
            .overlay {
                Rectangle().strokeBorder(isSelected ? Color.yellow : Color.primary.opacity(0.15), lineWidth: isSelected ? 2 : 1)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottomTrailing) {
                if row == layout.rowCount - 1 {
                    Text(temporal ? duration.map(DurationLabel.short) ?? "—" : String(localized: "Still"))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .foregroundStyle(.white).background(.black.opacity(0.65))
                        .padding(3).allowsHitTesting(false)
                }
            }
            .overlay(alignment: .leading) {
                FilmstripIndicators(cellID: cell.id, player: player, isSelected: isSelected,
                                    skimFraction: skimFraction, row: row, layout: layout)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard skimmable else { return }
                switch phase {
                case .active(let point):
                    guard FootageDragSession.shared.item == nil else { endSkim(); return }
                    skimFraction = layout.fraction(row: row, x: point.x)
                    onSkim(skimFraction)
                case .ended: endSkim()
                }
            }
            .onTapGesture { point in
                guard skimmable else { return }
                skimFraction = nil
                onSeek(layout.fraction(row: row, x: point.x))
            }
            .background {
                if skimmable {
                    FilmstripSwipeSurface { delta in
                        guard FootageDragSession.shared.item == nil else { return }
                        let start = skimFraction ?? (player?.loadedCellID == cell.id ? player?.playbackFraction : nil)
                            ?? layout.fraction(row: row, x: 0)
                        skimFraction = min(1, max(0, start + delta / layout.length))
                        onSkim(skimFraction)
                    }
                }
            }
            .accessibilityIdentifier("filmstrip.\(cell.id).row.\(row)")
            .accessibilityLabel("\(cell.title), footage preview")
    }

    private func endSkim() {
        skimFraction = nil
        onSkim(nil)
    }
}

private struct FilmstripIndicators: View {
    let cellID: UUID
    let player: FootagePlayer?
    let isSelected: Bool
    let skimFraction: Double?
    let row: Int
    let layout: FilmstripLayout

    var body: some View {
        ZStack(alignment: .leading) {
            if let fraction = player?.loadedCellID == cellID ? player?.playbackFraction : (isSelected ? 0 : nil),
               let x = layout.position(fraction: fraction, row: row) {
                indicator(.white).offset(x: x - 1)
            }
            if let skimFraction, let x = layout.position(fraction: skimFraction, row: row) {
                indicator(.orange).offset(x: x - 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func indicator(_ color: Color) -> some View {
        Rectangle().fill(color).frame(width: 2)
            .overlay(alignment: .top) {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: 9)).foregroundStyle(color).offset(y: -4)
            }
            .shadow(color: .black.opacity(0.8), radius: 1)
    }
}

private struct FilmstripFrames: View {
    let cell: FootageCell
    let duration: TimeInterval?
    let startFraction: Double
    let endFraction: Double
    let width: CGFloat
    @State private var frames: [CGImage] = []
    private var count: Int { max(1, Int(ceil(width / FilmstripLayout.posterWidth))) }
    private var request: String { "\(cell.id)|\(cell.mediaURL?.path ?? "")|\(duration ?? 0)|\(startFraction)|\(endFraction)|\(count)" }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                if frames.indices.contains(index) {
                    Image(decorative: frames[index], scale: 1).resizable().scaledToFill()
                        .frame(width: FilmstripLayout.posterWidth, height: FilmstripLayout.height).clipped()
                } else {
                    FootageThumbnail(thumbnailURL: cell.thumbnailURL, videoURL: nil,
                                     icon: cell.kind.symbolName, duration: nil)
                        .frame(width: FilmstripLayout.posterWidth, height: FilmstripLayout.height)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .accessibilityHidden(true)
        .task(id: request) {
            frames = []
            guard cell.kind == .video, let url = cell.mediaURL, let duration, duration > 0 else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 136)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            for index in 0..<count {
                guard !Task.isCancelled else { generator.cancelAllCGImageGeneration(); return }
                let fraction = startFraction + (endFraction - startFraction) * min(1, (Double(index) + 0.5) * FilmstripLayout.posterWidth / width)
                let time = CMTime(seconds: min(max(0, duration - 0.04), fraction * duration), preferredTimescale: 600)
                guard let image = try? await generator.image(at: time).image, !Task.isCancelled else { return }
                frames.append(image)
            }
        }
    }
}

/// Observe horizontal trackpad swipes without stealing mouse drags from the
/// timeline drag source or vertical scrolling from the library.
private struct FilmstripSwipeSurface: NSViewRepresentable {
    let onSwipe: (CGFloat) -> Void
    func makeNSView(context: Context) -> Surface { Surface(onSwipe: onSwipe) }
    func updateNSView(_ view: Surface, context: Context) { view.onSwipe = onSwipe }
    static func dismantleNSView(_ view: Surface, coordinator: ()) { view.detach() }

    final class Surface: NSView {
        var onSwipe: (CGFloat) -> Void
        private var monitor: Any?
        init(onSwipe: @escaping (CGFloat) -> Void) { self.onSwipe = onSwipe; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            detach()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.visibleRect.contains(self.convert(event.locationInWindow, from: nil)),
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                self.onSwipe(event.scrollingDeltaX)
                return nil
            }
        }
        func detach() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
