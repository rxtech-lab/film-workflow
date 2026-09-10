import Foundation
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
    let onDeselect: (() -> Void)?

    @Binding private var pixelsPerSecond: Double
    @State private var dragState = ClipDragState()
    @State private var hoveredHandle: TrimHandleID?
    @State private var dropTarget: (trackID: UUID, time: TimeInterval)?
    /// The footage being dragged over the lanes, decoded on entry so the
    /// ghost clip can take its real length.
    @State private var dragPreviewItem: FootageDragItem?
    @State private var thumbnails: [String: CGImage] = [:]

    private let headerWidth: CGFloat = 64
    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 52
    private let snapTolerancePixels: Double = 8

    public init(
        timeline: Binding<Timeline>,
        playhead: Binding<TimeInterval>,
        selectedClipID: Binding<UUID?>,
        pixelsPerSecond: Binding<Double>,
        resolver: (any MediaResolver)? = nil,
        onDrop: @escaping (FootageDragItem, UUID, TimeInterval) -> Void,
        onDeleteClip: ((UUID) -> Void)? = nil,
        onDeselect: (() -> Void)? = nil
    ) {
        _timeline = timeline
        _playhead = playhead
        _selectedClipID = selectedClipID
        _pixelsPerSecond = pixelsPerSecond
        self.resolver = resolver
        self.onDrop = onDrop
        self.onDeleteClip = onDeleteClip
        self.onDeselect = onDeselect
    }

    private var contentDuration: TimeInterval {
        var extent = max(timeline.duration, playhead)
        if let dropTarget, let dragPreviewItem {
            extent = max(extent, dropTarget.time + dragPreviewItem.defaultClipDuration)
        }
        return max(extent + 10, 30)
    }
    private var contentWidth: CGFloat { CGFloat(contentDuration * pixelsPerSecond) }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geometry in
                let canvasHeight = max(geometry.size.height, rulerHeight + CGFloat(timeline.tracks.count) * (laneHeight + 1))
                let canvasWidth = max(contentWidth, geometry.size.width - headerWidth - 1)

                // Headers and lanes share vertical scrolling so they never drift apart.
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        trackHeaders
                        Divider()
                        ScrollView(.horizontal) {
                            ZStack(alignment: .topLeading) {
                                VStack(spacing: 0) {
                                    ruler
                                    ForEach(timeline.tracks) { track in
                                        lane(track, width: canvasWidth)
                                        Divider()
                                    }
                                    Spacer(minLength: 0)
                                        .frame(maxWidth: .infinity)
                                        .contentShape(Rectangle())
                                        .gesture(DragGesture(minimumDistance: 0).onChanged { _ in deselect() })
                                }
                                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                                playheadLine(height: canvasHeight)
                            }
                            .coordinateSpace(name: "timelineCanvas")
                        }
                        .defaultScrollAnchor(.topLeading)
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: canvasHeight, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { deselect() }
                }
                .defaultScrollAnchor(.topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        .onDeleteCommand { deleteSelection() }
        .onKeyPress(.delete) { deleteSelection(); return .handled }
    }

    // MARK: - Toolbar

    private func deselect() {
        selectedClipID = nil
        onDeselect?()
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Menu {
                Button {
                    TimelineEditor.addTrack(&timeline, kind: .video)
                } label: {
                    Label("Video Track", systemImage: "film")
                }
                Button {
                    TimelineEditor.addTrack(&timeline, kind: .audio)
                } label: {
                    Label("Audio Track", systemImage: "waveform")
                }
                Button {
                    TimelineEditor.addTrack(&timeline, kind: .overlay)
                } label: {
                    Label("Overlay Track", systemImage: "square.3.layers.3d")
                }
            } label: {
                Label("Add Track", systemImage: "plus")
            }
            .fixedSize()
            .help("Add a video, audio or overlay track")
            Text("\(timeline.width)×\(timeline.height) · \(timeline.fps) fps")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(Timecode.string(seconds: playhead, fps: timeline.fps))
                .font(.system(.callout, design: .monospaced))
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            // A logarithmic scale keeps the wider zoom-out range easy to adjust.
            Slider(value: Binding(
                get: { log2(min(400, max(0.5, pixelsPerSecond))) },
                set: { pixelsPerSecond = pow(2, $0) }
            ), in: log2(0.5)...log2(400))
                .frame(width: 140)
                .controlSize(.small)
                .accessibilityLabel("Timeline zoom")
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
                .onChanged { value in
                    deselect()
                    playhead = timeline.quantized(max(0, value.location.x / pixelsPerSecond))
                }
        )
    }

    private var rulerStep: TimeInterval {
        let candidates: [TimeInterval] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 * pixelsPerSecond >= 70 } ?? 600
    }

    // MARK: - Lanes

    private func lane(_ track: Track, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(laneColor(track.kind))
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            deselect()
                            playhead = timeline.quantized(max(0, value.location.x / pixelsPerSecond))
                        }
                )
            ForEach(track.clips) { clip in
                clipView(clip, on: track)
            }
        }
        .frame(width: width, height: laneHeight, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if let dropTarget, dropTarget.trackID == track.id {
                if let dragPreviewItem {
                    dropGhost(dragPreviewItem, start: dropTarget.time, allowed: dragPreviewItem.canBePlaced(on: track.kind))
                } else {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.6))
                        .frame(width: 2, height: laneHeight)
                        .offset(x: CGFloat(dropTarget.time * pixelsPerSecond))
                }
            }
        }
        .onDrop(of: [.rxFootage], delegate: FootageLaneDropDelegate(
            entered: { item in
                dragPreviewItem = item
                Task { await loadThumbnail(for: item.source) }
            },
            // The ghost always sits under the pointer on the hovered lane; a
            // lane that cannot hold the kind shows it as not allowed.
            hover: { point in
                if let point {
                    dropTarget = (track.id, landingTime(for: dragPreviewItem, at: point.x / pixelsPerSecond, on: track))
                } else {
                    dropTarget = nil
                }
            },
            accepts: { item in item.canBePlaced(on: track.kind) },
            drop: { item, point in
                dropTarget = nil
                dragPreviewItem = nil
                guard item.canBePlaced(on: track.kind) else { return }
                onDrop(item, track.id, landingTime(for: item, at: point.x / pixelsPerSecond, on: track))
            }
        ))
    }

    /// Where footage would start from a pointer time: snapped to nearby clip
    /// edges and pushed past any clip already there.
    private func landingTime(for item: FootageDragItem?, at raw: TimeInterval, on track: Track) -> TimeInterval {
        let duration = item?.defaultClipDuration ?? FootageDragItem.defaultStillDuration
        return snappedDropTime(max(0, raw), duration: duration, on: track)
    }

    /// The clip as it will sit once dropped: its real length at the current
    /// zoom, its thumbnail, and the start and end timecodes it will get.
    private func dropGhost(_ item: FootageDragItem, start: TimeInterval, allowed: Bool) -> some View {
        let duration = item.defaultClipDuration
        let width = max(4, CGFloat(duration * pixelsPerSecond))
        let inset: CGFloat = 3
        let tint: Color = allowed ? .accentColor : .red
        let startLabel = Timecode.string(seconds: start, fps: timeline.fps)
        let endLabel = Timecode.string(seconds: start + duration, fps: timeline.fps)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5)
                .fill((allowed ? item.source.kind.clipColor : Color.red).opacity(allowed ? 0.55 : 0.3))
            if let image = thumbnails[item.source.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: min(width - 8, 70), height: laneHeight - inset * 2 - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.leading, 4)
                    .padding(.top, 2)
                    .opacity(0.8)
            }
            Text(allowed ? item.source.displayName : placementHint(for: item.source.kind))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(alignment: .topLeading) {
                    Rectangle().fill(.black.opacity(0.35)).frame(height: 14)
                }
            HStack(spacing: 4) {
                Text(startLabel)
                if width > 150 {
                    Spacer(minLength: 0)
                    Text(endLabel)
                }
            }
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
        .frame(width: width, height: laneHeight - inset * 2)
        .clipped()
        .overlay(alignment: .topLeading) {
            // The end time sits past the clip when there is no room inside it.
            if width <= 150 {
                Text(endLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 4)
                    .background(.background.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .offset(x: width + 4, y: laneHeight - inset * 2 - 14)
                    .fixedSize()
            }
        }
        .offset(x: CGFloat(start * pixelsPerSecond), y: inset)
        .allowsHitTesting(false)
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
                .fill(clip.source.kind.clipColor.opacity(isSelected ? 1 : 0.85))
            if let image = thumbnails[clip.source.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: min(width - 8, 70), height: laneHeight - inset * 2 - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.leading, 4)
            }
            if clip.source.kind.hasAudio, let resolver {
                ClipWaveformView(
                    source: clip.source,
                    resolver: resolver,
                    inPoint: clip.inPoint + (isDragging && dragState.mode == .trimLeading ? dragState.previewStart - clip.start : 0),
                    duration: isDragging ? dragState.previewDuration : clip.duration,
                    volume: track.isMuted ? 0 : clip.volume
                )
                .frame(height: clip.source.kind == .audio ? 28 : 14)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .allowsHitTesting(false)
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
            if isDragging {
                dragReadout(alignment: dragState.mode == .trimLeading ? .bottomLeading : .bottomTrailing)
            }
        }
        .frame(width: width, height: laneHeight - inset * 2)
        .offset(x: x, y: inset)
        .contentShape(Rectangle())
        .pointerStyle(isDragging && dragState.mode == .move ? .grabActive : .grabIdle)
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

    /// The length and edge times of the clip being moved or trimmed.
    private func dragReadout(alignment: Alignment) -> some View {
        let start = dragState.previewStart
        let end = start + dragState.previewDuration
        let text = dragState.mode == .move
            ? "\(Timecode.string(seconds: start, fps: timeline.fps)) – \(Timecode.string(seconds: end, fps: timeline.fps))"
            : "\(Timecode.string(seconds: dragState.previewDuration, fps: timeline.fps)) · \(Timecode.string(seconds: dragState.mode == .trimLeading ? start : end, fps: timeline.fps))"
        return Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
            .padding(3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            .allowsHitTesting(false)
    }

    /// Which lanes take a kind, for the not-allowed ghost.
    private func placementHint(for kind: SourceKind) -> String {
        let names = TrackKind.allCases.filter { $0.accepts(kind) }.map { kind -> String in
            switch kind {
            case .video: return "video"
            case .audio: return "audio"
            case .overlay: return "overlay"
            }
        }
        return "Drop on \(names.joined(separator: " or ")) track"
    }

    /// A grab zone on each end of a clip. The pointer becomes a resize arrow
    /// as it nears the edge, and the edge lights up so the zone is visible.
    private func trimHandle(_ clip: Clip, leading: Bool) -> some View {
        let id = TrimHandleID(clipID: clip.id, leading: leading)
        let active = dragState.clipID == clip.id && dragState.mode == (leading ? .trimLeading : .trimTrailing)
        let lit = active || hoveredHandle == id
        return Rectangle()
            .fill(Color.white.opacity(lit ? 0.22 : 0.001))
            .frame(width: 10)
            .overlay(alignment: leading ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 3, height: laneHeight * 0.45)
                    .padding(.horizontal, 2)
                    .opacity(lit ? 1 : 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(.frameResize(position: leading ? .leading : .trailing))
            .onHover { inside in
                if inside {
                    hoveredHandle = id
                } else if hoveredHandle == id {
                    hoveredHandle = nil
                }
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

    private func playheadLine(height: CGFloat) -> some View {
        Color.clear
            .frame(width: 14, height: height)
            .contentShape(Rectangle())
            .overlay {
                Rectangle().fill(Color.red).frame(width: 1.5)
            }
            .overlay(alignment: .top) {
                Triangle().fill(Color.red).frame(width: 10, height: 7).offset(y: -1)
            }
            .offset(x: CGFloat(playhead * pixelsPerSecond) - 7)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
                    .onChanged { value in
                        deselect()
                        playhead = timeline.quantized(max(0, value.location.x / pixelsPerSecond))
                    }
            )
    }
}

/// Reports the pointer while footage hovers a lane and decodes the payload
/// on release. `DropInfo.location` is in the lane's own coordinates, so the
/// drop time is simply x over the zoom.
private struct FootageLaneDropDelegate: DropDelegate {
    /// The payload, decoded as soon as the drag enters the lane.
    let entered: (FootageDragItem) -> Void
    let hover: (CGPoint?) -> Void
    /// Whether the lane can hold the item; false shows the forbidden cursor.
    let accepts: (FootageDragItem) -> Bool
    let drop: (FootageDragItem, CGPoint) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.rxFootage])
    }

    func dropEntered(info: DropInfo) {
        hover(info.location)
        if let item = FootageDragSession.shared.item {
            entered(item)
            return
        }
        guard let provider = info.itemProviders(for: [.rxFootage]).first else { return }
        let entered = entered
        Task { @MainActor in
            if let item = await provider.footageItem() { entered(item) }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        hover(info.location)
        if let item = FootageDragSession.shared.item, !accepts(item) {
            return DropProposal(operation: .forbidden)
        }
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        hover(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        if let item = FootageDragSession.shared.item {
            FootageDragSession.shared.end()
            drop(item, location)
            return true
        }
        guard let provider = info.itemProviders(for: [.rxFootage]).first else {
            hover(nil)
            return false
        }
        let drop = drop
        Task { @MainActor in
            guard let item = await provider.footageItem() else { return }
            drop(item, location)
        }
        return true
    }
}

private extension NSItemProvider {
    func footageItem() async -> FootageDragItem? {
        await withCheckedContinuation { continuation in
            _ = loadTransferable(type: FootageDragItem.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}

private struct TrimHandleID: Hashable {
    let clipID: UUID
    let leading: Bool
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
