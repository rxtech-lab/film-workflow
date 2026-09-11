import Foundation

public enum RemotionJSON: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([RemotionJSON]), object([String: RemotionJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([RemotionJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: RemotionJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public struct OpenStreetMapConfiguration: Codable, Equatable, Sendable {
    public var tileURL: String
    public var attribution: String
    public var minimumZoom: Int
    public var maximumZoom: Int
    /// A provider contract must allow automated movie exports.
    public var allowsExport: Bool
    public var headers: [String: String]
    public init(tileURL: String, attribution: String, minimumZoom: Int = 0, maximumZoom: Int = 19,
                allowsExport: Bool, headers: [String: String] = [:]) {
        self.tileURL = tileURL; self.attribution = attribution
        self.minimumZoom = minimumZoom; self.maximumZoom = maximumZoom
        self.allowsExport = allowsExport; self.headers = headers
    }
}

public struct RemotionConfiguration: Codable, Equatable, Sendable {
    public var openStreetMap: OpenStreetMapConfiguration?
    public var frameTimeout: TimeInterval
    public init(openStreetMap: OpenStreetMapConfiguration? = nil, frameTimeout: TimeInterval = 30) {
        self.openStreetMap = openStreetMap; self.frameTimeout = frameTimeout
    }
}

public struct RemotionComposition: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let width: Int
    public let height: Int
    public let fps: Double
    public let durationInFrames: Int
    public var duration: TimeInterval { Double(durationInFrames) / fps }
}

public struct RemotionRenderSettings: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, Sendable { case h264, proRes4444 }
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var codec: Codec
    /// nil selects a conservative device-based worker count. Set 1 for serial rendering.
    public var concurrency: Int?
    /// Scale captured pixels without changing the composition's logical viewport or timing.
    /// Nil keeps full resolution. Preview intermediates can use a value greater than zero and at most one.
    public var captureScale: Double?
    public init(width: Int? = nil, height: Int? = nil, fps: Double? = nil, codec: Codec = .h264, concurrency: Int? = nil,
                captureScale: Double? = nil) {
        self.width = width; self.height = height; self.fps = fps; self.codec = codec; self.concurrency = concurrency
        self.captureScale = captureScale
    }
    func capturedComposition(_ composition: RemotionComposition) -> RemotionComposition {
        let scale = captureScale ?? 1
        return RemotionComposition(id: composition.id, width: max(1, Int((Double(composition.width) * scale).rounded())),
                                   height: max(1, Int((Double(composition.height) * scale).rounded())),
                                   fps: composition.fps, durationInFrames: composition.durationInFrames)
    }
    func workerCount(for composition: RemotionComposition) -> Int {
        let info = ProcessInfo.processInfo
        let automatic = info.activeProcessorCount >= 4 && info.physicalMemory >= 8 * 1024 * 1024 * 1024
            && composition.width * composition.height <= 3840 * 2160 ? 2 : 1
        return min(composition.durationInFrames, max(1, min(4, concurrency ?? automatic)))
    }

}

public struct RemotionProgress: Sendable {
    public enum Stage: String, Sendable { case preparing, compiling, rendering, encoding }
    public let stage: Stage
    public let fraction: Double?
    public let detail: String?
    public init(stage: Stage, fraction: Double? = nil, detail: String? = nil) {
        self.stage = stage; self.fraction = fraction; self.detail = detail
    }
}

public enum RemotionError: LocalizedError, Sendable {
    case resource(String), compilation(String), rendering(String), unsupported(String), disposed
    public var errorDescription: String? {
        switch self {
        case .resource(let s), .compilation(let s), .rendering(let s), .unsupported(let s): return s
        case .disposed: return "The Remotion session has been closed."
        }
    }
}

public enum RemotionPlaybackEvent: Sendable {
    case building, ready(RemotionComposition), frame(Int), buffering(Bool), ended, error(String), limitation(String)
}

struct RemotionAudioSample: Codable, Sendable {
    let id: String
    let src: String
    let frame: Int
    let mediaFrame: Double
    let volume: Double
    let playbackRate: Double
    let toneFrequency: Double?
    let audioStartFrame: Double?
    let audioStreamIndex: Int?
}

public struct RemotionDiagnostic: Sendable, Equatable {
    public enum Category: String, Sendable { case compilation, resource, capture, unsupported, lifecycle }
    public let category: Category
    public let message: String
    public let file: String?
    public let line: Int?
    public let column: Int?
}

extension RemotionError {
    /// Structured source locations when the browser compiler supplies them.
    public var diagnostic: RemotionDiagnostic {
        let message = errorDescription ?? "Remotion error"
        let category: RemotionDiagnostic.Category = switch self {
        case .compilation: .compilation
        case .resource: .resource
        case .rendering: .capture
        case .unsupported: .unsupported
        case .disposed: .lifecycle
        }
        let expression = try? NSRegularExpression(pattern: #"(?:project:)?([^\s:]+\.(?:tsx?|jsx?|mjs|css|json)):(\d+):(\d+)"#)
        let match = expression?.firstMatch(in: message, range: NSRange(message.startIndex..., in: message))
        func part(_ index: Int) -> String? {
            guard let match, let range = Range(match.range(at: index), in: message) else { return nil }
            return String(message[range])
        }
        return RemotionDiagnostic(category: category, message: message, file: part(1),
                                  line: part(2).flatMap(Int.init), column: part(3).flatMap(Int.init))
    }
}
