import Foundation
import SwiftUI
import UniformTypeIdentifiers
import VideoEditorCore
import VideoEffectsCore
import VideoEffectsUI

enum ModifierDropTarget: Equatable {
    case effect(UUID)
    case transition(TransitionAttachment)
}

enum ModifierDropHitTesting {
    static func target(item: ModifierDragItem, point: CGPoint, track: Track, timeline: Timeline, pixelsPerSecond: Double) -> ModifierDropTarget? {
        guard pixelsPerSecond > 0, track.kind != .audio else { return nil }
        let time = point.x / pixelsPerSecond
        if item.kind == .transition {
            let clips = track.sortedClips
            for (left, right) in zip(clips, clips.dropFirst()) where abs(left.end - right.start) < 0.000001 {
                // A cut is a one-pixel target, so the join zone reaches well into
                // both clips while leaving the shorter clip's In and Out reachable.
                let tolerance = Self.joinTolerance(shorterClipWidth: min(left.duration, right.duration) * pixelsPerSecond)
                if abs(point.x - left.end * pixelsPerSecond) <= tolerance,
                   timeline.acceptsModifiers(on: left.id), timeline.acceptsModifiers(on: right.id) {
                    return .transition(.between(outgoing: left.id, incoming: right.id))
                }
            }
        }
        guard let clip = track.clip(at: time), timeline.acceptsModifiers(on: clip.id) else { return nil }
        if item.kind == .effect { return .effect(clip.id) }
        return .transition(time < clip.start + clip.duration / 2 ? .start(clip.id) : .end(clip.id))
    }

    /// Pixels on either side of a cut that drop a joined transition.
    static func joinTolerance(shorterClipWidth: Double) -> Double {
        min(40, shorterClipWidth / 5)
    }
}

struct ModifierLaneDropDelegate: DropDelegate {
    let target: (ModifierDragItem, CGPoint) -> Bool
    let exited: () -> Void
    let drop: @MainActor (ModifierDragItem, CGPoint) -> Void
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.videoModifier]) }
    func dropEntered(info: DropInfo) {
        if let item = ModifierDragSession.shared.item { _ = target(item, info.location) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard let item = ModifierDragSession.shared.item else { return DropProposal(operation: .copy) }
        return DropProposal(operation: target(item, info.location) ? .copy : .forbidden)
    }
    func dropExited(info: DropInfo) { exited() }
    func performDrop(info: DropInfo) -> Bool {
        let location = info.location
        exited()
        if let item = ModifierDragSession.shared.item {
            ModifierDragSession.shared.end()
            drop(item, location)
            return true
        }
        guard let provider = info.itemProviders(for: [.videoModifier]).first else { return false }
        let drop = drop
        provider.loadDataRepresentation(forTypeIdentifier: UTType.videoModifier.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(ModifierDragItem.self, from: data) else { return }
            Task { @MainActor in drop(item, location) }
        }
        return true
    }
}

struct TimelineModifierRegions: View {
    @Binding var timeline: Timeline
    let track: Track
    let pixelsPerSecond: Double
    let laneHeight: CGFloat
    let selectedTransitionID: UUID?
    let onInspectEffects: (UUID) -> Void
    let onInspectTransition: (UUID) -> Void
    let onError: (String) -> Void
    let movedStarts: [UUID: Double]
    let laneOffset: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(track.clips.filter { !$0.effects.isEmpty }) { clip in
                effectBadge(clip)
            }
            ForEach(timeline.transitions.filter { !$0.attachment.clipIDs.isDisjoint(with: Set(track.clips.map(\.id))) }) { item in
                if let range = item.range(in: timeline) {
                    let member = item.attachment.clipIDs.first(where: { movedStarts[$0] != nil })
                    let shift = member.flatMap { id in timeline.clip(id: id).map { (movedStarts[id] ?? $0.start) - $0.start } } ?? 0
                    TransitionRegion(item: item, timeline: timeline, pixelsPerSecond: pixelsPerSecond, height: laneHeight - 6,
                                     selected: selectedTransitionID == item.id,
                                     onSelect: { onInspectTransition(item.id) }, onCommit: { duration in
                        var candidate = timeline
                        do { try TimelineEditor.updateTransition(&candidate, id: item.id) { $0.duration = duration }; timeline = candidate }
                        catch { onError(error.localizedDescription) }
                    }, onError: onError, onDelete: {
                        var candidate = timeline
                        TimelineEditor.removeTransition(&candidate, id: item.id)
                        timeline = candidate
                    })
                    .offset(x: (range.lowerBound + shift) * pixelsPerSecond,
                            y: 3 + (member == nil ? 0 : CGFloat(laneOffset) * (laneHeight + 1)))
                }
            }
        }
    }
    private func effectBadge(_ clip: Clip) -> some View {
        let start = movedStarts[clip.id] ?? clip.start
        let x = CGFloat(max(0, (start + clip.duration / 2) * pixelsPerSecond - 10))
        let y = CGFloat(19) + (movedStarts[clip.id] == nil ? CGFloat.zero : CGFloat(laneOffset) * (laneHeight + 1))
        return Button { onInspectEffects(clip.id) } label: {
            Image(systemName: "fx").font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain).foregroundStyle(Color.white).offset(x: x, y: y)
        .help("Inspect \(clip.effects.count) effects")
        .accessibilityIdentifier("clip-effects-\(clip.id)")
    }

}

private struct TransitionRegion: View {
    let item: TransitionInstance
    let timeline: Timeline
    let pixelsPerSecond: Double
    let height: CGFloat
    let selected: Bool
    let onSelect: () -> Void
    let onCommit: (Double) -> Void
    let onError: (String) -> Void
    let onDelete: () -> Void
    @State private var draft: Double?
    @State private var resizeError: String?
    private var duration: Double { draft ?? item.duration }
    private var width: Double { max(22, duration * pixelsPerSecond) }
    private var name: String { ModifierCatalog.current.transition(item.definitionID)?.name ?? "Unavailable transition" }
    private var leadingOffset: Double {
        var preview = item
        preview.duration = duration
        guard let original = item.range(in: timeline), let resized = preview.range(in: timeline) else { return 0 }
        return (resized.lowerBound - original.lowerBound) * pixelsPerSecond
    }
    var body: some View {
        HStack(spacing: 0) {
            if item.attachment.isPair || isEnd { handle(leading: true) }
            Button(action: onSelect) {
                Text(LocalizedStringKey(name)).font(.caption2.weight(.semibold)).lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(name)
            if item.attachment.isPair || !isEnd { handle(leading: false) }
        }
        .frame(width: width, height: height)
        .foregroundStyle(.white)
        .background((selected ? Color.purple : Color.indigo).opacity(item.isEnabled ? 0.82 : 0.4), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? .white : .white.opacity(0.45), lineWidth: selected ? 2 : 1))
        .offset(x: leadingOffset)
        .help("\(name) · \(duration.formatted(.number.precision(.fractionLength(2)))) s. Drag an edge to resize.")
        .accessibilityIdentifier("transition-\(item.id)")
        .contextMenu {
            Button("Inspect Transition", action: onSelect)
            Button("Remove Transition", role: .destructive, action: onDelete)
        }
        .overlay {
            // The readout stays inside this lane: lanes below draw on top, so
            // anything hung beneath the chip would be hidden by their clips.
            if draft != nil {
                Text("\(duration.formatted(.number.precision(.fractionLength(2)))) s")
                    .font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 3))
                    .fixedSize().allowsHitTesting(false)
            }
        }
    }
    private var isEnd: Bool { if case .end = item.attachment { return true }; return false }
    private func handle(leading: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(.white.opacity(0.85)).frame(width: 2, height: height * 0.6)
            .frame(width: 8, height: height).contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .pointerStyle(.frameResize(position: leading ? .leading : .trailing))
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timelineCanvas")).onChanged { value in
                onSelect()
                let delta = value.translation.width / pixelsPerSecond * (leading ? -1 : 1) * (item.attachment.isPair ? 2 : 1)
                let wanted = max(timeline.frameDuration, timeline.quantized(item.duration + delta))
                var candidate = timeline
                do {
                    try TimelineEditor.updateTransition(&candidate, id: item.id) { $0.duration = wanted }
                    draft = wanted; resizeError = nil
                } catch { resizeError = error.localizedDescription }
            }.onEnded { _ in
                if let resizeError { onError(resizeError) }
                else if let draft { onCommit(draft) }
                draft = nil; resizeError = nil
            })
            .accessibilityLabel(leading ? "Transition leading handle" : "Transition trailing handle")
    }
}
