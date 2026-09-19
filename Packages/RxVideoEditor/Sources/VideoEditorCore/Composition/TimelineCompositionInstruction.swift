import AVFoundation
import CoreGraphics
import Foundation
import VideoEffectsCore

/// One drawable in a segment, bottom to top.
public indirect enum LayerSpec: @unchecked Sendable {
    /// Frames from a composition track. `preferredTransform` undoes camera
    /// rotation; `naturalSize` is the frame size before that transform.
    case sourceTrack(CMPersistentTrackID, transform: ClipTransform, opacity: Float, preferredTransform: CGAffineTransform, naturalSize: CGSize)
    case still(URL, transform: ClipTransform, opacity: Float)
    /// Cues already shifted onto the timeline clock.
    case text([TextCue], style: TextStyle)
    /// A clip whose media does not exist yet (an unrendered Remotion clip).
    case placeholder(String)
    case processed(LayerSpec, [EffectInstance])
    case recording(LayerSpec, clip: Clip)
    case heldEdges(LayerSpec, playable: Range<Double>, first: CGImage?, last: CGImage?, transform: ClipTransform, opacity: Float)
    case transition(from: LayerSpec?, to: LayerSpec?, instance: TransitionInstance, range: Range<Double>)

    func sourceTrackIDs(at time: Double) -> [CMPersistentTrackID] {
        switch self {
        case .sourceTrack(let id, _, _, _, _): return [id]
        case .processed(let layer, _), .recording(let layer, _): return layer.sourceTrackIDs(at: time)
        case .heldEdges(let layer, let range, _, _, _, _): return range.contains(time) ? layer.sourceTrackIDs(at: time) : []
        case .transition(let from, let to, _, _): return (from?.sourceTrackIDs(at: time) ?? []) + (to?.sourceTrackIDs(at: time) ?? [])
        default: return []
        }
    }
}

/// The per-segment instruction handed to `TimelineVideoCompositor`.
public final class TimelineCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    public let timeRange: CMTimeRange
    public let enablePostProcessing: Bool = false
    /// Text and stills change every frame; asking AVFoundation to tween
    /// keeps it from reusing a frame across the segment.
    public let containsTweening: Bool = true
    public let requiredSourceTrackIDs: [NSValue]?
    public let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid

    public let layers: [LayerSpec]
    public let backgroundColor: CGColor

    public init(timeRange: CMTimeRange, layers: [LayerSpec], sourceTrackIDs: [CMPersistentTrackID], backgroundColor: CGColor) {
        self.timeRange = timeRange
        self.layers = layers
        self.requiredSourceTrackIDs = sourceTrackIDs.map { NSNumber(value: $0) }
        self.backgroundColor = backgroundColor
        super.init()
    }
}
