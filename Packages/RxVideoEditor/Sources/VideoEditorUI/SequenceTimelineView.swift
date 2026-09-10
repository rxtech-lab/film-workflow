import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore

/// The timeline panel: ruler, track lanes, clips, playhead, zoom, drag and
/// drop, move and trim. All edits go through `TimelineEditor` so the
/// timeline stays valid.
public struct SequenceTimelineView: View {
    @Binding var timeline: Timeline
    @Binding var playhead: TimeInterval
    @Binding var selectedClipID: UUID?
    let resolver: (any MediaResolver)?
    /// Called with the dropped item, the track and the snapped drop time.
    let onDrop: (FootageDragItem, UUID, TimeInterval) -> Void
    let onDeleteClip: ((UUID) -> Void)?

    @State private var pixelsPerSecond: Double = 40
    @State private var dragState = ClipDragState()
    @State private var dropTarget: (trackID: UUID, time: TimeInterval)?
    @State private var thumbnails: [String: CGImage] = [:]

    private let headerWidth: CGFloat = 64
    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 52
    private let snapTolerancePixels: Double = 8

    public init(
        timeline: Binding<Timeline>,
        playhead: Binding<TimeInterval>,
        selectedClipID: Binding<UUID?>,
        resolver: (any MediaResolver)? = nil,
        onDrop: @escaping (FootageDragItem, UUID, TimeInterval) -> Void,
        onDeleteClip: ((UUID) -> Void)? = nil
    ) {
        _timeline = timeline
        _playhead = playhead
        _selectedClipID = selectedClipID
        self.resolver = resolver
        self.onDrop = onDrop
        self.onDeleteClip = onDeleteClip
    }

    private var contentDuration: TimeInterval { max(timeline.duration + 10, 30) }
    private var contentWidth: CGFloat { CGFloat(contentDuration * pixelsPerSecond) }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                trackHeaders
                Divider()
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            ruler
                            ForEach(timeline.tracks) { track in
                                lane(track)
                                Divider()
                            }
                        }
                        .frame(width: contentWidth)
                        playheadLine
                    }
                }
            }
        }
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(.delete) { deleteSelection(); return .handled }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("\(timeline.width)×\(timeline.height) · \(timeline.fps) fps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Timecode.string(seconds: playhead, fps: timeline.fps))
                .font(.system(.callout, design: .monospaced))
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: $pixelsPerSecond, in: 8...400)
                .frame(width: 140)
                .controlSize(.small)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Headers

    private var trackHeaders: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach($timeline.tracks) { $track in
                HStack(spacing: 4) {
                    Text(track.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if track.kind != .overlay {
                        Button {
                            track.isMuted.toggle()
                        } label: {
                            Image(systemName: track.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.caption2)
                        }
                        .buttonStyle(.borderless)
                        .help(track.isMuted ? "Unmute" : "Mute")
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: laneHeight)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .frame(width: headerWidth)
        .background(.bar)
    }

    // MARK: - Ruler

    private var ruler: some View {
        let step = rulerStep
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary.opacity(0.4))
            ForEach(Array(stride(from: 0.0, through: contentDuration, by: step)), id: \.self) { t in
                VStack(alignment: .leading, spacing: 0) {
                    Text(Timecode.string(seconds: t, fps: timeline.fps).dropFirst(3))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Rectangle().fill(.secondary).frame(width: 1, height: 6)
                }
                .offset(x: CGFloat(t * pixelsPerSecond))
            }
        }
        .frame(height: rulerHeight)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in playhead = timeline.quantized(max(0, value.location.x / pixelsPerSecond)) }
        )
    }

    private var rulerStep: TimeInterval {
        let candidates: [TimeInterval] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 * pixelsPerSecond >= 70 } ?? 600
    }

    // MARK: - Lanes

    private func lane(_ track: Track) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(laneColor(track.kind))
                .contentShape(Rectangle())
                .onTapGesture { location in
                    selectedClipID = nil
                    playhead = timeline.quantized(max(0, location.x / pixelsPerSecond))
                }
            ForEach(track.clips) { clip in
                clipView(clip, on: track)
            }
            if let dropTarget, dropTarget.trackID == track.id {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 2, height: laneHeight)
                    .offset(x: CGFloat(dropTarget.time * pixelsPerSecond))
            }
        }
        .frame(width: contentWidth, height: laneHeight)
        .dropDestination(for: FootageDragItem.self) { items, location in
            dropTarget = nil
            guard let item = items.first, track.kind.accepts(item.source.kind) else { return false }
            let time = snappedDropTime(location.x / pixelsPerSecond, duration: item.defaultClipDuration, on: track)
            onDrop(item, track.id, time)
            return true
        } isTargeted: { targeted in
            if !targeted, dropTarget?.trackID == track.id { dropTarget = nil }
        }
        .onContinuousHover { phase in
            // Hover feedback for the drop position happens through isTargeted;
            // continuous hover keeps the indicator following the pointer.
            if case .active(let point) = phase, dropTarget?.trackID == track.id {
                dropTarget = (track.id, timeline.quantized(max(0, point.x / pixelsPerSecond)))
            }
        }
    }

    private func snappedDropTime(_ raw: TimeInterval, duration: TimeInterval, on track: Track) -> TimeInterval {
        let points = TimelineEditor.snapPoints(timeline)
        let snapped = TimelineEditor.snapped(max(0, raw), to: points, tolerance: snapTolerancePixels / pixelsPerSecond)
        return TimelineEditor.nextFreeStart(timeline, on: track.id, at: snapped, duration: duration) ?? snapped
    }

    private func laneColor(_ kind: TrackKind) -> Color {
        switch kind {
        case .video: return Color(nsColor: .controlBackgroundColor)
        case .audio: return Color(nsColor: .controlBackgroundColor).opacity(0.7)
        case .overlay: return Color(nsColor: .controlBackgroundColor).opacity(0.5)
        }
    }

    // MARK: - Clips

    private func clipView(_ clip: Clip, on track: Track) -> some View {
        let isSelected = selectedClipID == clip.id
        let isDragging = dragState.clipID == clip.id
        let x = CGFloat((isDragging ? dragState.previewStart : clip.start) * pixelsPerSecond)
        let width = max(4, CGFloat((isDragging ? dragState.previewDuration : clip.duration) * pixelsPerSecond))
        let inset: CGFloat = 3

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(clipColor(clip.source.kind).opacity(isSelected ? 1 : 0.85))
            if let image = thumbnails[clip.source.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: min(width - 8, 70), height: laneHeight - inset * 2 - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.leading, 4)
            }
            Text(clip.source.displayName)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.top, 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.35)).frame(height: 14)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5))
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            // Trim handles.
            HStack {
                trimHandle(clip, leading: true)
                Spacer(minLength: 0)
                trimHandle(clip, leading: false)
            }
        }
        .frame(width: width, height: laneHeight - inset * 2)
        .offset(x: x, y: inset)
        .contentShape(Rectangle())
        .onTapGesture { selectedClipID = clip.id }
        .gesture(moveGesture(clip, on: track))
        .contextMenu {
            Button("Split at Playhead") { split(clip) }
                .disabled(!(clip.start < playhead && playhead < clip.end))
            Button("Delete", role: .destructive) { delete(clip.id) }
            Button("Ripple Delete", role: .destructive) { try? TimelineEditor.rippleDelete(&timeline, clipID: clip.id) }
        }
        .task(id: clip.source.id) { await loadThumbnail(for: clip.source) }
        .help("\(clip.source.displayName) · \(Timecode.string(seconds: clip.duration, fps: timeline.fps))")
    }

    private func clipColor(_ kind: SourceKind) -> Color {
        switch kind {
        case .video: return Color(red: 0.30, green: 0.45, blue: 0.72)
        case .remotion: return Color(red: 0.52, green: 0.36, blue: 0.75)
        case .image: return Color(red: 0.35, green: 0.62, blue: 0.55)
        case .audio: return Color(red: 0.25, green: 0.60, blue: 0.35)
        case .captions: return Color(red: 0.80, green: 0.55, blue: 0.20)
        }
    }

    private func trimHandle(_ clip: Clip, leading: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if dragState.clipID != clip.id {
                            dragState = ClipDragState(clipID: clip.id, mode: leading ? .trimLeading : .trimTrailing, originalStart: clip.start, originalDuration: clip.duration)
                        }
                        let delta = value.translation.width / pixelsPerSecond
                        if leading {
                            let start = snap(clip.start + delta, excluding: clip.id)
                            let bounded = min(max(0, start), clip.end - timeline.frameDuration)
                            dragState.previewStart = bounded
                            dragState.previewDuration = clip.end - bounded
                        } else {
                            let end = snap(clip.end + delta, excluding: clip.id)
                            dragState.previewDuration = max(timeline.frameDuration, end - clip.start)
                        }
                    }
                    .onEnded { _ in
                        defer { dragState = ClipDragState() }
                        selectedClipID = clip.id
                        if leading {
                            try? TimelineEditor.trimLeading(&timeline, clipID: clip.id, by: dragState.previewStart - clip.start)
                        } else {
                            try? TimelineEditor.trimTrailing(&timeline, clipID: clip.id, by: dragState.previewDuration - clip.duration)
                        }
                    }
            )
    }

    private func moveGesture(_ clip: Clip, on track: Track) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if dragState.clipID != clip.id {
                    dragState = ClipDragState(clipID: clip.id, mode: .move, originalStart: clip.start, originalDuration: clip.duration)
                    selectedClipID = clip.id
                }
                let raw = clip.start + value.translation.width / pixelsPerSecond
                dragState.previewStart = max(0, snap(raw, excluding: clip.id))
                dragState.previewDuration = clip.duration
                // Vertical travel picks another lane of a compatible kind.
                let laneOffset = Int((value.translation.height / laneHeight).rounded())
                if let index = timeline.tracks.firstIndex(where: { $0.id == track.id }) {
                    let target = min(max(0, index + laneOffset), timeline.tracks.count - 1)
                    dragState.targetTrackID = timeline.tracks[target].kind.accepts(clip.source.kind) ? timeline.tracks[target].id : track.id
                }
            }
            .onEnded { _ in
                defer { dragState = ClipDragState() }
                let target = dragState.targetTrackID ?? track.id
                try? TimelineEditor.move(&timeline, clipID: clip.id, to: dragState.previewStart, onTrack: target)
            }
    }

    private func snap(_ time: TimeInterval, excluding clipID: UUID) -> TimeInterval {
        var points = TimelineEditor.snapPoints(timeline, excluding: clipID)
        points.append(playhead)
        return timeline.quantized(TimelineEditor.snapped(time, to: points, tolerance: snapTolerancePixels / pixelsPerSecond))
    }

    private func split(_ clip: Clip) {
        if let right = try? TimelineEditor.split(&timeline, clipID: clip.id, at: playhead) {
            selectedClipID = right
        }
    }

    private func delete(_ id: UUID) {
        if let onDeleteClip {
            onDeleteClip(id)
        } else {
            TimelineEditor.remove(&timeline, clipID: id)
        }
        if selectedClipID == id { selectedClipID = nil }
    }

    private func deleteSelection() {
        guard let selectedClipID else { return }
        delete(selectedClipID)
    }

    private func loadThumbnail(for source: ClipSource) async {
        guard thumbnails[source.id] == nil, let resolver, source.kind != .audio, source.kind != .captions else { return }
        if let image = await resolver.thumbnail(for: source, at: 0.5) {
            thumbnails[source.id] = image
        }
    }

    // MARK: - Playhead

    private var playheadLine: some View {
        let height = rulerHeight + CGFloat(timeline.tracks.count) * (laneHeight + 1)
        return Rectangle()
            .fill(Color.red)
            .frame(width: 1.5, height: height)
            .overlay(alignment: .top) {
                Triangle().fill(Color.red).frame(width: 10, height: 7).offset(y: -1)
            }
            .offset(x: CGFloat(playhead * pixelsPerSecond))
            .allowsHitTesting(false)
    }
}

private struct ClipDragState {
    enum Mode { case move, trimLeading, trimTrailing }
    var clipID: UUID?
    var mode: Mode = .move
    var originalStart: TimeInterval = 0
    var originalDuration: TimeInterval = 0
    var previewStart: TimeInterval = 0
    var previewDuration: TimeInterval = 0
    var targetTrackID: UUID?

    init() {}

    init(clipID: UUID, mode: Mode, originalStart: TimeInterval, originalDuration: TimeInterval) {
        self.clipID = clipID
        self.mode = mode
        self.originalStart = originalStart
        self.originalDuration = originalDuration
        self.previewStart = originalStart
        self.previewDuration = originalDuration
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
