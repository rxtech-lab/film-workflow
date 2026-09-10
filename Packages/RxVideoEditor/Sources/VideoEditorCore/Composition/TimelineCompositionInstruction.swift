import AVFoundation
import CoreGraphics
import Foundation

/// One drawable in a segment, bottom to top.
public enum LayerSpec: @unchecked Sendable {
    /// Frames from a composition track. `preferredTransform` undoes camera
    /// rotation; `naturalSize` is the frame size before that transform.
    case sourceTrack(CMPersistentTrackID, transform: ClipTransform, opacity: Float, preferredTransform: CGAffineTransform, naturalSize: CGSize)
    case still(URL, transform: ClipTransform, opacity: Float)
    /// Cues already shifted onto the timeline clock.
    case text([TextCue], style: TextStyle)
    /// A clip whose media does not exist yet (an unrendered Remotion clip).
    case placeholder(String)
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
