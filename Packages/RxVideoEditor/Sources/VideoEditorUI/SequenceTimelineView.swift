import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore

/// A context-menu offer to line a clip up with the clip it came from.
/// `targetClipID` is nil when the origin isn't on the timeline; the item then
/// shows disabled so the relationship is still visible.
nonisolated public struct ClipAlignment: Hashable, Sendable {
    public var title: String
    public var targetClipID: UUID?

    public init(title: String, targetClipID: UUID?) {
        self.title = title
        self.targetClipID = targetClipID
    }
}

/// The timeline panel: ruler, track lanes, clips, playhead, zoom, drag and
/// drop, move and trim. All edits go through `TimelineEditor` so the
/// timeline stays valid.
///
/// Selection holds any number of clips: click picks one, command- or
/// shift-click toggles, and dragging across empty lane space sweeps a
/// selection rectangle. A selected group moves and deletes together.
public struct SequenceTimelineView: View {
    @Binding var timeline: Timeline
    @Binding var playhead: TimeInterval
    @Binding var selectedClipIDs: Set<UUID>
    let resolver: (any MediaResolver)?
    /// Called with the dropped item, the track and the snapped drop time.
    let onDrop: (FootageDragItem, UUID, TimeInterval) -> Void
    /// Called with every clip to delete in one edit; nil removes them directly.
    let onDeleteClips: ((Set<UUID>) -> Void)?
    let onDeselect: (() -> Void)?
    /// Offers "Align with …" on clips derived from another clip. Nil hides the item.
    let alignment: ((Clip, Timeline) -> ClipAlignment?)?

    @Binding private var pixelsPerSecond: Double
    @State private var dragState = ClipDragState()
    @State private var hoveredHandle: TrimHandleID?
    @State private var hoveredRetimeHandle: TrimHandleID?
    @State private var dropTarget: (trackID: UUID, time: TimeInterval)?
    /// The footage being dragged over the lanes, decoded on entry so the
    /// ghost clip can take its real length.
    @State private var dragPreviewItem: FootageDragItem?
    @State private var thumbnails: [String: CGImage] = [:]
    /// Where the pointer is over the canvas, as a frame-quantized time. Drawn
    /// as a gray skimmer line; a click turns it into the playhead.
    @State private var hoverTime: TimeInterval?
    @State private var tool: TimelineTool = .select
    @State private var speedClipID: UUID?
    @State private var editError: String?
    @State private var sourceDurations: [String: TimeInterval] = [:]
    @FocusState private var timelineFocused: Bool
    /// The lanes' horizontal scroll, driven when the zoom changes so the
    /// playhead (or the visible centre) keeps its screen position.
    @State private var scrollPosition = ScrollPosition(x: 0)
    @State private var viewport = TimelineViewport()
    /// The zoom when a trackpad pinch began; the pinch scales from here.
    @State private var pinchBaseZoom: Double?
    /// The selection rectangle being swept across the lanes, if any.
    @State private var marquee: MarqueeSelection?

    private static let zoomRange: ClosedRange<Double> = 0.5...400
    private let headerWidth: CGFloat = 64
    private let rulerHeight: CGFloat = 24
    private let laneHeight: CGFloat = 52
    private let snapTolerancePixels: Double = 8

    public init(
        timeline: Binding<Timeline>,
        playhead: Binding<TimeInterval>,
        selectedClipIDs: Binding<Set<UUID>>,
        pixelsPerSecond: Binding<Double>,
        resolver: (any MediaResolver)? = nil,
        onDrop: @escaping (FootageDragItem, UUID, TimeInterval) -> Void,
        onDeleteClips: ((Set<UUID>) -> Void)? = nil,
        onDeselect: (() -> Void)? = nil,
        alignment: ((Clip, Timeline) -> ClipAlignment?)? = nil
    ) {
        _timeline = timeline
        _playhead = playhead
        _selectedClipIDs = selectedClipIDs
        _pixelsPerSecond = pixelsPerSecond
        self.resolver = resolver
        self.onDrop = onDrop
        self.onDeleteClips = onDeleteClips
        self.onDeselect = onDeselect
        self.alignment = alignment
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
            editingToolbar
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
                                        .gesture(marqueeGesture(scrubs: false))
                                }
                                .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
                                hoverIndicator(height: canvasHeight)
                                playheadLine(height: canvasHeight)
                                marqueeOverlay
                            }
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case .active(let point):
                                    hoverTime = timeline.quantized(min(max(0, point.x / pixelsPerSecond), contentDuration))
                                case .ended:
                                    hoverTime = nil
                                }
                            }
                            .coordinateSpace(name: "timelineCanvas")
                        }
                        .defaultScrollAnchor(.topLeading)
                        .scrollPosition($scrollPosition)
                        .onScrollGeometryChange(for: TimelineViewport.self) { geometry in
                            TimelineViewport(offsetX: geometry.contentOffset.x, width: geometry.containerSize.width)
                        } action: { _, latest in
                            viewport = latest
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(height: canvasHeight, alignment: .top)
                    .contentShape(Rectangle())
                    .onTapGesture { deselect() }
                }
                .defaultScrollAnchor(.topLeading)
                .simultaneousGesture(pinchToZoom)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

        .focusable()
        .focusEffectDisabled()
        .focused($timelineFocused)
        .onDeleteCommand { deleteSelection() }
        .onKeyPress(.delete) { deleteSelection(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "bB")) { _ in tool = .blade; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "aA")) { _ in tool = .select; return .handled }
        .onKeyPress(.escape) { tool = .select; return .handled }
        .popover(isPresented: Binding(get: { speedClipID != nil }, set: { if !$0 { speedClipID = nil } })) {
            if let speedClipID { ClipSpeedEditor(timeline: $timeline, clipID: speedClipID) }
        }
        .alert("Couldn’t edit footage", isPresented: Binding(get: { editError != nil }, set: { if !$0 { editError = nil } })) {
            Button("OK") { editError = nil }
        } message: { Text(editError ?? "") }
        .onChange(of: pixelsPerSecond) { previous, current in
            keepAnchorInPlace(from: previous, to: current)
        }
    }

    private static func clampedZoom(_ zoom: Double) -> Double {
        min(zoomRange.upperBound, max(zoomRange.lowerBound, zoom))
    }

    /// Trackpad pinch over the lanes: spreading zooms in, pinching zooms out,
    /// scaled from the zoom at the start of the gesture.
    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBaseZoom ?? pixelsPerSecond
                pinchBaseZoom = base
                pixelsPerSecond = Self.clampedZoom(base * value.magnification)
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }

    /// Re-scrolls the lanes after a zoom so the playhead stays under the same
    /// screen x; when the playhead is out of view the visible centre holds
    /// still instead, so the user never loses their place.
    private func keepAnchorInPlace(from previous: Double, to current: Double) {
        guard viewport.width > 0, previous > 0, current > 0, previous != current else { return }
        let offset = TimelineViewport.scrollOffset(
            keeping: playhead, from: previous, to: current, offsetX: viewport.offsetX, viewportWidth: viewport.width
        )
        scrollPosition.scrollTo(x: offset)
    }

    // MARK: - Toolbar

    private func deselect() {
        timelineFocused = true
        selectedClipIDs = []
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
                get: { log2(Self.clampedZoom(pixelsPerSecond)) },
                set: { pixelsPerSecond = pow(2, $0) }
            ), in: log2(Self.zoomRange.lowerBound)...log2(Self.zoomRange.upperBound))
                .frame(width: 140)
                .controlSize(.small)
                .accessibilityLabel("Timeline zoom")
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// The one selected clip, for edits that only make sense on a single clip.
    private var selectedClip: Clip? {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return nil }
        return timeline.clip(id: id)
    }

    private var editingToolbar: some View {
        HStack(spacing: 8) {
            Button { tool = .select; timelineFocused = true } label: {
                Label("Select", systemImage: "cursorarrow")
            }
            .tint(tool == .select ? .accentColor : .secondary)
            .help("Selection tool (A)")
            .accessibilityIdentifier("timeline.tool.select")
            Button { tool = .blade; timelineFocused = true } label: {
                Label("Cut", systemImage: "scissors")
            }
            .tint(tool == .blade ? .accentColor : .secondary)
            .help("Blade tool (B): click footage to split it")
            .accessibilityIdentifier("timeline.tool.cut")
            Divider().frame(height: 16)
            Button { speedClipID = selectedClip?.id } label: {
                Label("Speed", systemImage: "speedometer")
            }
            .disabled(selectedClip?.source.capabilities.contains(.speed) != true)
            .accessibilityIdentifier("timeline.speed")
            Button {
                if let selectedClip { performEdit { try TimelineEditor.reverse(&timeline, clipID: selectedClip.id) } }
            } label: {
                Label("Reverse", systemImage: "backward.end")
            }
            .tint(selectedClip?.isReversed == true ? .accentColor : .secondary)
            .disabled(selectedClip?.source.capabilities.contains(.reverse) != true)
            .accessibilityIdentifier("timeline.reverse")
            Spacer()
            if selectedClipIDs.count > 1 {
                Text("\(selectedClipIDs.count) clips selected")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("timeline.selection.count")
            } else if let selectedClip, selectedClip.source.capabilities.contains(.speed) {
                Text("\((selectedClip.playbackRate * 100).formatted(.number.precision(.fractionLength(0...3))))%\(selectedClip.isReversed ? " · Reversed" : "")")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(.bar)
    }

    private func performEdit(_ edit: () throws -> Void) {
        do { try edit() } catch { editError = error.localizedDescription }
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
                .gesture(marqueeGesture(scrubs: true))
            ForEach(track.clips) { clip in
                clipView(clip, on: track)
            }
        }
        .frame(width: width, height: laneHeight, alignment: .topLeading)
        // Clips previewing a lane change draw over the lanes they cross.
        .zIndex(dragState.laneOffset != 0 && track.clips.contains { dragState.movedStarts[$0.id] != nil } ? 1 : 0)
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
                    .frame(width: max(0, min(width - 8, 70)), height: laneHeight - inset * 2 - 4)
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
        let isSelected = selectedClipIDs.contains(clip.id)
        let isDragging = dragState.clipID == clip.id
        // A clip moving with the grabbed one previews at its shifted start.
        let movedStart = dragState.movedStarts[clip.id]
        let x = CGFloat((movedStart ?? (isDragging ? dragState.previewStart : clip.start)) * pixelsPerSecond)
        let width = max(4, CGFloat((isDragging ? dragState.previewDuration : clip.duration) * pixelsPerSecond))
        let inset: CGFloat = 3
        let y = inset + (movedStart == nil ? 0 : CGFloat(dragState.laneOffset) * (laneHeight + 1))
        let displayedClip = isDragging ? (dragState.previewClip ?? clip) : clip
        let showsSpeed = TimelineClipInteraction.showsSpeedOverlay(for: clip) || (isDragging && dragState.mode.isRetiming)

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(clip.source.kind.clipColor.opacity(isSelected ? 1 : 0.85))
            if let image = thumbnails[clip.source.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: max(0, min(width - 8, 70)), height: laneHeight - inset * 2 - 4)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(.leading, 4)
            }
            if clip.source.kind.hasAudio, let resolver {
                ClipWaveformView(
                    source: clip.source,
                    resolver: resolver,
                    inPoint: displayedClip.inPoint,
                    duration: displayedClip.duration,
                    playbackRate: displayedClip.playbackRate,
                    isReversed: clip.isReversed,
                    volume: track.isMuted ? 0 : clip.volume
                )
                .frame(height: clip.source.kind == .audio ? 28 : 14)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                if showsSpeed { speedOverlay(displayedClip, width: width) }
                Text(clip.source.displayName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.35))
                Spacer(minLength: 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? Color.white : Color.black.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            if isDragging {
                dragReadout(alignment: dragState.mode.isLeading ? .bottomLeading : .bottomTrailing)
            }
        }
        .frame(width: width, height: laneHeight - inset * 2)
        .contentShape(Rectangle())
        .overlay {
            if tool == .select, clip.source.capabilities.contains(.duration) {
                HStack(spacing: 0) {
                    trimHandle(clip, leading: true, width: width)
                    Spacer(minLength: 0)
                    trimHandle(clip, leading: false, width: width)
                }
                .allowsHitTesting(false)
            }
        }
        .pointerStyle(clipPointer(clip))
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let mode = TimelineClipInteraction.mode(at: location.x, y: location.y, width: width, capabilities: clip.source.capabilities, tool: tool, showsSpeedOverlay: showsSpeed)
                hoveredRetimeHandle = mode?.isRetiming == true
                    ? TrimHandleID(clipID: clip.id, leading: mode == .retimeLeading) : nil
                hoveredHandle = mode == .trimLeading || mode == .trimTrailing
                    ? TrimHandleID(clipID: clip.id, leading: mode == .trimLeading) : nil
            case .ended:
                if hoveredHandle?.clipID == clip.id { hoveredHandle = nil }
                if hoveredRetimeHandle?.clipID == clip.id { hoveredRetimeHandle = nil }
            }
        }
        .onTapGesture { location in
            timelineFocused = true
            let time = timeline.quantized(min(max(0, clip.start + location.x / pixelsPerSecond), clip.end))
            if tool == .blade {
                if clip.source.capabilities.contains(.cut) { split(clip, at: time) }
            } else if Self.isAdditiveSelection {
                if selectedClipIDs.contains(clip.id) { selectedClipIDs.remove(clip.id) } else { selectedClipIDs.insert(clip.id) }
            } else {
                selectedClipIDs = [clip.id]
                playhead = time
            }
        }
        .simultaneousGesture(
            SpatialTapGesture(count: 2).onEnded { value in
                let mode = TimelineClipInteraction.mode(
                    at: value.location.x, y: value.location.y, width: width,
                    capabilities: clip.source.capabilities, tool: tool, showsSpeedOverlay: showsSpeed
                )
                guard mode == .retimeTrailing else { return }
                performEdit { try TimelineEditor.changeSpeed(&timeline, clipID: clip.id, rate: 1) }
            }
        )
        .gesture(clipGesture(clip, on: track, width: width))
        .offset(x: x, y: y)
        .contextMenu {
            // Destructive items act on the whole selection when this clip is part of it.
            let targets = selectedClipIDs.contains(clip.id) ? selectedClipIDs : [clip.id]
            Button("Split at Playhead") { split(clip, at: playhead) }
                .disabled(!clip.source.capabilities.contains(.cut) || !(clip.start < playhead && playhead < clip.end))
            Button("Change Speed…") { selectedClipIDs = [clip.id]; speedClipID = clip.id }
                .disabled(!clip.source.capabilities.contains(.speed))
            Button(clip.isReversed ? "Play Forward" : "Reverse") { performEdit { try TimelineEditor.reverse(&timeline, clipID: clip.id) } }
                .disabled(!clip.source.capabilities.contains(.reverse))
            if let alignment = alignment?(clip, timeline) {
                Button(alignment.title) {
                    guard let target = alignment.targetClipID else { return }
                    performEdit { try TimelineEditor.align(&timeline, clipID: clip.id, with: target) }
                }
                .disabled(alignment.targetClipID == nil)
            }
            Button(targets.count > 1 ? "Delete \(targets.count) Clips" : "Delete", role: .destructive) { delete(targets) }
            Button(targets.count > 1 ? "Ripple Delete \(targets.count) Clips" : "Ripple Delete", role: .destructive) {
                performEdit { try TimelineEditor.rippleDelete(&timeline, clipIDs: targets) }
                selectedClipIDs.subtract(targets)
            }
        }
        .task(id: clip.source.id) {
            await loadThumbnail(for: clip.source)
            await loadSourceDuration(for: clip)
        }
        .help("\(clip.source.displayName) · \(Timecode.string(seconds: clip.duration, fps: timeline.fps))")
    }

    /// The amber strip represents the same source range, stretched to its
    /// current timeline duration. Only its ends retime; lower edges still trim.
    private func speedOverlay(_ clip: Clip, width: CGFloat) -> some View {
        HStack(spacing: 0) {
            speedHandle(clip, leading: true, width: width)
            Text("\((clip.playbackRate * 100).formatted(.number.precision(.fractionLength(0...2))))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .clipped()
            speedHandle(clip, leading: false, width: width)
        }
        .foregroundStyle(.black.opacity(0.9))
        .frame(width: width, height: TimelineClipInteraction.speedOverlayHeight)
        .background(Color.orange.opacity(0.95))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed \((clip.playbackRate * 100).formatted()) percent")
        .accessibilityIdentifier("timeline.clip.speed.\(clip.id)")
        .help("Drag either end to change speed. Double-click the right end to restore 100%.")
    }

    private func speedHandle(_ clip: Clip, leading: Bool, width: CGFloat) -> some View {
        let hovered = hoveredRetimeHandle == TrimHandleID(clipID: clip.id, leading: leading)
        let active = dragState.clipID == clip.id && dragState.mode == (leading ? .retimeLeading : .retimeTrailing)
        return RoundedRectangle(cornerRadius: 1)
            .fill(.black.opacity(0.6))
            .frame(width: 2, height: 10)
            .frame(width: TimelineClipInteraction.handleWidth(for: width), height: TimelineClipInteraction.speedOverlayHeight)
            .background(.white.opacity(hovered || active ? 0.4 : 0.15))
    }

    /// The length and edge times of the clip being moved or trimmed.
    private func dragReadout(alignment: Alignment) -> some View {
        let start = dragState.previewStart
        let end = start + dragState.previewDuration
        let text = dragState.mode == .move
            ? "\(Timecode.string(seconds: start, fps: timeline.fps)) – \(Timecode.string(seconds: end, fps: timeline.fps))"
            : "\(Timecode.string(seconds: dragState.previewDuration, fps: timeline.fps)) · \(Timecode.string(seconds: dragState.mode.isLeading ? start : end, fps: timeline.fps))"
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
    private func trimHandle(_ clip: Clip, leading: Bool, width: CGFloat) -> some View {
        let id = TrimHandleID(clipID: clip.id, leading: leading)
        let active = dragState.clipID == clip.id && dragState.mode == (leading ? .trimLeading : .trimTrailing)
        let lit = active || hoveredHandle == id
        return Rectangle()
            .fill(Color.white.opacity(lit ? 0.22 : 0.001))
            .frame(width: TimelineClipInteraction.handleWidth(for: width))
            .overlay(alignment: leading ? .leading : .trailing) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(.white)
                    .frame(width: 2, height: laneHeight * 0.45)
                    .padding(.horizontal, 1)
                    .opacity(lit ? 1 : 0)
            }
    }

    private func clipPointer(_ clip: Clip) -> PointerStyle {
        if tool == .blade {
            return clip.source.capabilities.contains(.cut)
                ? .image(Image(systemName: "scissors"), hotSpot: .center) : .image(Image(systemName: "nosign"), hotSpot: .center)
        }
        if let handle = hoveredRetimeHandle, handle.clipID == clip.id {
            return .frameResize(position: handle.leading ? .leading : .trailing)
        }
        if let handle = hoveredHandle, handle.clipID == clip.id {
            return .frameResize(position: handle.leading ? .leading : .trailing)
        }
        return clip.source.capabilities.contains(.drag)
            ? (dragState.clipID == clip.id ? .grabActive : .grabIdle) : .default
    }

    /// A single gesture chooses an edge or body at mouse-down. A fixed canvas
    /// coordinate space keeps the trailing edge from drifting as its width changes.
    private func clipGesture(_ clip: Clip, on track: Track, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                if dragState.clipID == nil {
                    let localX = value.startLocation.x - clip.start * pixelsPerSecond
                    let trackIndex = timeline.tracks.firstIndex { $0.id == track.id } ?? 0
                    let localY = value.startLocation.y - rulerHeight - CGFloat(trackIndex) * (laneHeight + 1) - 3
                    guard let mode = TimelineClipInteraction.mode(at: localX, y: localY, width: width, capabilities: clip.source.capabilities, tool: tool,
                                                                  showsSpeedOverlay: TimelineClipInteraction.showsSpeedOverlay(for: clip)) else { return }
                    dragState = ClipDragState(clipID: clip.id, mode: mode, originalStart: clip.start, originalDuration: clip.duration)
                    timelineFocused = true
                    if mode == .move {
                        // Grabbing a selected clip drags the whole selection along;
                        // clips that cannot be dragged stay where they are.
                        let selection = selectedClipIDs.contains(clip.id) ? selectedClipIDs : [clip.id]
                        selectedClipIDs = selection
                        let moving = timeline.allClips.filter { selection.contains($0.id) && $0.source.capabilities.contains(.drag) }
                        dragState.groupIDs = Set(moving.map(\.id))
                        dragState.movedStarts = Dictionary(uniqueKeysWithValues: moving.map { ($0.id, $0.start) })
                    }
                }
                guard dragState.clipID == clip.id else { return }
                var preview = timeline
                let delta = value.translation.width / pixelsPerSecond
                let natural = sourceDurations[clip.source.id] ?? clip.sourceDuration
                do {
                    switch dragState.mode {
                    case .trimLeading:
                        try TimelineEditor.trimLeading(&preview, clipID: clip.id, by: snap(clip.start + delta, excluding: clip.id) - clip.start, sourceDuration: natural)
                    case .trimTrailing:
                        try TimelineEditor.trimTrailing(&preview, clipID: clip.id, by: snap(clip.end + delta, excluding: clip.id) - clip.end, sourceDuration: natural)
                    case .retimeLeading:
                        let start = min(clip.end - timeline.frameDuration, max(0, snap(clip.start + delta, excluding: clip.id)))
                        try TimelineEditor.retime(&preview, clipID: clip.id, duration: clip.end - start, anchor: .end)
                    case .retimeTrailing:
                        let end = max(clip.start + timeline.frameDuration, snap(clip.end + delta, excluding: clip.id))
                        try TimelineEditor.retime(&preview, clipID: clip.id, duration: end - clip.start)
                    case .move:
                        // The group changes lane only when every clip fits its new lane.
                        let requested = Int((value.translation.height / (laneHeight + 1)).rounded())
                        let laneOffset = TimelineEditor.canShiftLanes(timeline, clipIDs: dragState.groupIDs, by: requested) ? requested : 0
                        let moveDelta = snap(clip.start + delta, excluding: dragState.groupIDs) - clip.start
                        try TimelineEditor.move(&preview, clipIDs: dragState.groupIDs, by: moveDelta, laneOffset: laneOffset)
                        dragState.laneOffset = laneOffset
                        dragState.moveDelta = moveDelta
                        for id in dragState.groupIDs {
                            if let moved = preview.clip(id: id) { dragState.movedStarts[id] = moved.start }
                        }
                    }
                    if let updated = preview.clip(id: clip.id) {
                        dragState.previewClip = updated
                        dragState.previewStart = updated.start
                        dragState.previewDuration = updated.duration
                    }
                } catch { /* Keep the last valid preview at source bounds or neighbours. */ }
            }
            .onEnded { _ in
                defer { dragState = ClipDragState() }
                guard dragState.clipID == clip.id, let preview = dragState.previewClip else { return }
                let natural = sourceDurations[clip.source.id] ?? clip.sourceDuration
                performEdit {
                    switch dragState.mode {
                    case .trimLeading:
                        try TimelineEditor.trimLeading(&timeline, clipID: clip.id, by: preview.start - clip.start, sourceDuration: natural)
                    case .trimTrailing:
                        try TimelineEditor.trimTrailing(&timeline, clipID: clip.id, by: preview.duration - clip.duration, sourceDuration: natural)
                    case .retimeLeading:
                        try TimelineEditor.retime(&timeline, clipID: clip.id, duration: preview.duration, anchor: .end)
                    case .retimeTrailing:
                        try TimelineEditor.retime(&timeline, clipID: clip.id, duration: preview.duration)
                    case .move:
                        try TimelineEditor.move(&timeline, clipIDs: dragState.groupIDs, by: dragState.moveDelta, laneOffset: dragState.laneOffset)
                    }
                }
            }
    }

    private func loadSourceDuration(for clip: Clip) async {
        guard clip.source.kind != .image, sourceDurations[clip.source.id] == nil, let resolver else { return }
        guard let media = try? await resolver.resolve(clip.source), !Task.isCancelled else { return }
        switch media {
        case .file(let url, let duration, _):
            if let duration, duration > 0 { sourceDurations[clip.source.id] = duration }
            else { sourceDurations[clip.source.id] = await MediaDurationCache.duration(of: url) }
        case .captions(let cues): sourceDurations[clip.source.id] = cues.map(\.end).max()
        }
    }

    private func snap(_ time: TimeInterval, excluding clipID: UUID) -> TimeInterval {
        snap(time, excluding: [clipID])
    }

    private func snap(_ time: TimeInterval, excluding clipIDs: Set<UUID>) -> TimeInterval {
        var points = TimelineEditor.snapPoints(timeline, excluding: clipIDs)
        points.append(playhead)
        return timeline.quantized(TimelineEditor.snapped(time, to: points, tolerance: snapTolerancePixels / pixelsPerSecond))
    }

    private func split(_ clip: Clip, at time: TimeInterval) {
        if let right = try? TimelineEditor.split(&timeline, clipID: clip.id, at: time) {
            selectedClipIDs = [right]
        }
    }

    /// Removes the clips in one edit so a single undo brings them all back.
    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        if let onDeleteClips {
            onDeleteClips(ids)
        } else {
            TimelineEditor.remove(&timeline, clipIDs: ids)
        }
        selectedClipIDs.subtract(ids)
    }

    private func deleteSelection() {
        delete(selectedClipIDs)
    }

    /// Command or shift held: clicks and marquees add to the selection.
    private static var isAdditiveSelection: Bool {
        !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
    }

    // MARK: - Marquee selection

    /// A press on empty lane space. A click sets the playhead (and scrubs
    /// while the pointer stays put); once it travels past the threshold it
    /// sweeps a selection rectangle instead and the playhead stops moving.
    private func marqueeGesture(scrubs: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timelineCanvas"))
            .onChanged { value in
                if marquee == nil {
                    let additive = Self.isAdditiveSelection
                    marquee = MarqueeSelection(origin: value.startLocation, current: value.location, base: additive ? selectedClipIDs : [])
                    if additive { timelineFocused = true } else { deselect() }
                }
                guard var current = marquee else { return }
                current.current = value.location
                if !current.isActive,
                   max(abs(value.translation.width), abs(value.translation.height)) >= TimelineClipInteraction.marqueeThreshold {
                    current.isActive = true
                }
                if current.isActive {
                    selectedClipIDs = current.base.union(clipIDs(in: current.rect))
                } else if scrubs, current.base.isEmpty {
                    playhead = timeline.quantized(max(0, value.location.x / pixelsPerSecond))
                }
                marquee = current
            }
            .onEnded { _ in marquee = nil }
    }

    /// The clips a rectangle in canvas coordinates touches.
    private func clipIDs(in rect: CGRect) -> Set<UUID> {
        guard let lanes = TimelineClipInteraction.laneRange(
            minY: rect.minY, maxY: rect.maxY, rulerHeight: rulerHeight, laneHeight: laneHeight, laneCount: timeline.tracks.count
        ) else { return [] }
        let range = max(0, rect.minX / pixelsPerSecond)...max(0, rect.maxX / pixelsPerSecond)
        return TimelineEditor.clipIDs(timeline, intersecting: range, trackIndices: lanes)
    }

    @ViewBuilder
    private var marqueeOverlay: some View {
        if let marquee, marquee.isActive {
            let rect = marquee.rect
            Rectangle()
                .fill(Color.blue.opacity(0.18))
                .overlay(Rectangle().strokeBorder(Color.blue.opacity(0.8), lineWidth: 1))
                .frame(width: max(1, rect.width), height: max(1, rect.height))
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
                .accessibilityIdentifier("timeline.marquee")
        }
    }

    private func loadThumbnail(for source: ClipSource) async {
        guard thumbnails[source.id] == nil, let resolver, source.kind != .audio, source.kind != .captions else { return }
        if let image = await resolver.thumbnail(for: source, at: 0.5) {
            thumbnails[source.id] = image
        }
    }

    // MARK: - Playhead

    /// The gray skimmer that follows the pointer, with its timecode in the ruler.
    @ViewBuilder
    private func hoverIndicator(height: CGFloat) -> some View {
        if let hoverTime, hoverTime != playhead {
            let x = CGFloat(hoverTime * pixelsPerSecond)
            Rectangle()
                .fill(Color.gray.opacity(0.7))
                .frame(width: 1, height: height)
                .offset(x: x)
                .allowsHitTesting(false)
            Text(Timecode.string(seconds: hoverTime, fps: timeline.fps))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.gray, in: RoundedRectangle(cornerRadius: 3))
                .offset(x: x + 4, y: 2)
                .allowsHitTesting(false)
        }
    }

    private func playheadLine(height: CGFloat) -> some View {
        Color.clear
            .frame(width: 14, height: rulerHeight)
            .contentShape(Rectangle())
            .overlay(alignment: .top) {
                Rectangle().fill(Color.red).frame(width: 1.5, height: height).allowsHitTesting(false)
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

/// The visible slice of the lanes: how far they are scrolled and how wide
/// the scroll view is.
struct TimelineViewport: Equatable {
    var offsetX: CGFloat = 0
    var width: CGFloat = 0

    /// The horizontal scroll offset that keeps `playhead` at the same screen
    /// x after the zoom changes from `previous` to `current` pixels per
    /// second. If the playhead is not visible the viewport centre is the
    /// anchor instead. Never negative; the scroll view clamps the far end.
    static func scrollOffset(
        keeping playhead: TimeInterval,
        from previous: Double,
        to current: Double,
        offsetX: CGFloat,
        viewportWidth: CGFloat
    ) -> CGFloat {
        let playheadX = CGFloat(playhead * previous) - offsetX
        let anchorX: CGFloat
        let anchorTime: TimeInterval
        if playheadX >= 0, playheadX <= viewportWidth {
            anchorX = playheadX
            anchorTime = playhead
        } else {
            anchorX = viewportWidth / 2
            anchorTime = Double(offsetX + anchorX) / previous
        }
        return max(0, CGFloat(anchorTime * current) - anchorX)
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
    typealias Mode = TimelineClipInteraction.Mode
    /// The clip under the pointer.
    var clipID: UUID?
    var mode: Mode = .move
    var originalStart: TimeInterval = 0
    var originalDuration: TimeInterval = 0
    var previewStart: TimeInterval = 0
    var previewDuration: TimeInterval = 0
    var previewClip: Clip?
    /// Every clip moving with the grabbed one (the selection), for `.move`.
    var groupIDs: Set<UUID> = []
    /// Where each moving clip currently previews.
    var movedStarts: [UUID: TimeInterval] = [:]
    /// The last valid time shift and lane shift of the group.
    var moveDelta: TimeInterval = 0
    var laneOffset: Int = 0

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

/// A selection rectangle swept from `origin` to `current` in canvas
/// coordinates. `base` is the selection to keep when the sweep is additive.
private struct MarqueeSelection {
    var origin: CGPoint
    var current: CGPoint
    var base: Set<UUID>
    /// False until the pointer has travelled past the click threshold.
    var isActive = false

    var rect: CGRect {
        CGRect(
            x: min(origin.x, current.x), y: min(origin.y, current.y),
            width: abs(current.x - origin.x), height: abs(current.y - origin.y)
        )
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
