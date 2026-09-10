import AVFoundation
import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import VideoEditorCore

/// Sequences (timelines) and the footage that goes on them, for agents.
@MainActor
enum MCPSequenceHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "footage_list",
            description: "Every piece of footage in the film that can go on a timeline, with the `source_id` sequence tools take (e.g. `video:<uuid>`, `music:<uuid>`, `remotion:<uuid>`, `caption:<uuid>`, `imported:<uuid>`). Remotion sources are rendered automatically when a sequence renders.",
            inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ),
        MCPToolDescriptor(
            name: "import_media",
            description: "Bring a video, audio or image file from disk into the film as imported footage. Returns its source_id.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "Absolute path of the file."] as [String: Any],
                    "copy": ["type": "boolean", "description": "Copy into the film package (default true) or reference in place."] as [String: Any],
                    "name": ["type": "string", "description": "Display name; defaults to the file name."] as [String: Any],
                ],
                "required": ["path"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_list",
            description: "List the film's sequences (timelines) with size, frame rate, duration and render count.",
            inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ),
        MCPToolDescriptor(
            name: "sequence_create",
            description: "Create a sequence. Returns its id and the default tracks (T1 overlay, V1 video, A1/A2 audio).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string"] as [String: Any],
                    "width": ["type": "integer", "description": "Default 1920."] as [String: Any],
                    "height": ["type": "integer", "description": "Default 1080."] as [String: Any],
                    "fps": ["type": "integer", "description": "Default 30."] as [String: Any],
                ]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_get",
            description: "The full timeline of a sequence as JSON: tracks (id, kind, name) and clips (id, source, start, duration, inPoint, volume, opacity).",
            inputSchema: [
                "type": "object",
                "properties": ["sequence_id": ["type": "string"] as [String: Any]],
                "required": ["sequence_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_set_timeline",
            description: "Replace a sequence's timeline with the JSON shape returned by sequence_get. Validated: clips on one track must not overlap and must suit the track kind.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "timeline": ["type": "object", "description": "A timeline object as returned by sequence_get."] as [String: Any],
                ],
                "required": ["sequence_id", "timeline"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_add_clip",
            description: "Place footage on a track. Video/remotion/image go on a `video` track, music/narration on an `audio` track, captions on the `overlay` track. Omit `start` to append after the track's last clip; omit `duration` to use the footage's natural length (stills default to 5 s).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "source_id": ["type": "string", "description": "From footage_list."] as [String: Any],
                    "track": ["type": "string", "description": "Track name such as V1, A1, T1, or a track id. Defaults to the first track that accepts the footage."] as [String: Any],
                    "start": ["type": "number", "description": "Seconds on the timeline."] as [String: Any],
                    "duration": ["type": "number", "description": "Seconds."] as [String: Any],
                    "in_point": ["type": "number", "description": "Seconds into the source to start from."] as [String: Any],
                    "ripple": ["type": "boolean", "description": "Shift later clips right instead of failing on overlap."] as [String: Any],
                ],
                "required": ["sequence_id", "source_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_remove_clip",
            description: "Remove a clip from a sequence. `ripple` closes the gap.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "clip_id": ["type": "string"] as [String: Any],
                    "ripple": ["type": "boolean"] as [String: Any],
                ],
                "required": ["sequence_id", "clip_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_render",
            description: "Render a sequence, by default as a new mp4 version inside the film. Remotion clips without a current render are rendered first. Slow: minutes for long sequences.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "codec": ["type": "string", "enum": ["h264", "hevc", "none"], "description": "Video codec; `none` exports audio only. Default h264."] as [String: Any],
                    "audio": ["type": "string", "enum": ["aac", "none"], "description": "Audio codec; `none` drops every audio track. Default aac."] as [String: Any],
                    "resolution": ["type": "string", "enum": TimelineExporter.Resolution.allCases.map(\.rawValue), "description": "Longest edge of the picture, aspect kept. Default source."] as [String: Any],
                    "format": ["type": "string", "enum": TimelineExporter.Container.allCases.map(\.rawValue), "description": "Container. Audio-only always writes m4a. Default mp4."] as [String: Any],
                    "output_dir": ["type": "string", "description": "Absolute folder path. When given the file is written there as `<sequence name>.<ext>` and is not kept as a film version."] as [String: Any],
                ],
                "required": ["sequence_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_renders",
            description: "The rendered versions of a sequence, newest first, with file paths.",
            inputSchema: [
                "type": "object",
                "properties": ["sequence_id": ["type": "string"] as [String: Any]],
                "required": ["sequence_id"]
            ]
        ),
    ]

    private static let toolNames: Set<String> = Set(descriptors.map(\.name))

    static func canHandle(_ name: String) -> Bool { toolNames.contains(name) }

    static func handle(name: String, arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        switch name {
        case "footage_list": return try footageList(context: context)
        case "import_media": return try await importMedia(arguments, context: context)
        case "sequence_list": return try sequenceList(context: context)
        case "sequence_create": return try sequenceCreate(arguments, context: context)
        case "sequence_get": return try sequenceGet(arguments, context: context)
        case "sequence_set_timeline": return try sequenceSetTimeline(arguments, context: context)
        case "sequence_add_clip": return try await sequenceAddClip(arguments, context: context)
        case "sequence_remove_clip": return try sequenceRemoveClip(arguments, context: context)
        case "sequence_render": return try await sequenceRender(arguments, context: context)
        case "sequence_renders": return try sequenceRenders(arguments, context: context)
        default: throw MCPToolError.invalidArguments("unknown tool \(name)")
        }
    }

    // MARK: - Footage

    private static func footageList(context: ModelContext) throws -> [String: Any] {
        let index = LibraryIndex(
            music: try context.fetch(FetchDescriptor<MusicProject>()),
            narrations: try context.fetch(FetchDescriptor<NarrativeProject>()),
            captions: try context.fetch(FetchDescriptor<CaptionProject>()),
            images: try context.fetch(FetchDescriptor<ImageGenProject>()),
            videos: try context.fetch(FetchDescriptor<VideoGenProject>()),
            remotions: try context.fetch(FetchDescriptor<RemotionProject>()),
            imported: try context.fetch(FetchDescriptor<ImportedAsset>()),
            sequences: []
        )
        var items: [[String: Any]] = []
        for row in index.rows() where row.id.kind != .sequence {
            for cell in index.footage(for: row.id) {
                var entry: [String: Any] = [
                    "source_id": cell.drag.source.id,
                    "kind": cell.drag.source.kind.rawValue,
                    "project": row.name,
                    "project_kind": row.id.kind.rawValue,
                    "title": cell.title,
                    "subtitle": cell.subtitle,
                ]
                if let d = cell.drag.duration { entry["duration"] = d }
                items.append(entry)
            }
        }
        return MCPToolRegistry.jsonResult(items)
    }

    private static func importMedia(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        guard let path = arguments["path"] as? String else { throw MCPToolError.invalidArguments("missing path") }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw MCPToolError.invalidArguments("no file at \(path)") }
        guard let kind = MediaImportSheet.kind(of: url) else { throw MCPToolError.invalidArguments("not a video, audio or image file") }
        let copy = (arguments["copy"] as? Bool) ?? true
        let storage = ProjectStorage.forContainer(context.container)
        let asset = ImportedAsset(name: (arguments["name"] as? String) ?? url.deletingPathExtension().lastPathComponent, kind: kind, originalPath: url.path)
        do {
            if copy {
                asset.relativePath = try storage.copyFile(from: url, kind: .imported, fallbackExtension: kind == .image ? "png" : "mp4")
            } else {
                asset.bookmarkData = try url.bookmarkData()
            }
        } catch {
            throw MCPToolError.underlying(error)
        }
        let mediaURL = asset.relativePath.map(storage.absoluteURL(for:)) ?? url
        switch kind {
        case .video:
            if let probed = await VideoThumbnailer.probe(url: mediaURL) {
                asset.width = probed.width; asset.height = probed.height; asset.durationSeconds = probed.duration
            }
            asset.thumbnailFilePath = await VideoThumbnailer.generate(for: mediaURL, storage: storage)
        case .audio:
            let seconds = CMTimeGetSeconds(AVURLAsset(url: mediaURL).duration)
            asset.durationSeconds = seconds.isFinite ? seconds : 0
        case .image:
            if let image = NSImage(contentsOf: mediaURL) { asset.width = Int(image.size.width); asset.height = Int(image.size.height) }
        }
        context.insert(asset)
        try context.save()
        return MCPToolRegistry.jsonResult([
            "source_id": DocumentMediaResolver.sourceID(.imported, asset.id),
            "id": asset.id.uuidString,
            "kind": kind.rawValue,
            "duration": asset.durationSeconds,
            "width": asset.width,
            "height": asset.height,
            "stored": copy ? "copied" : "referenced",
        ] as [String: Any])
    }

    // MARK: - Sequences

    private static func fetchSequence(_ arguments: [String: Any], context: ModelContext) throws -> SequenceProject {
        guard let raw = arguments["sequence_id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("missing or malformed sequence_id")
        }
        guard let sequence = try context.fetch(FetchDescriptor<SequenceProject>(predicate: #Predicate { $0.id == id })).first else {
            throw MCPToolError.projectNotFound(raw)
        }
        return sequence
    }

    private static func summary(_ s: SequenceProject, context: ModelContext) -> [String: Any] {
        [
            "id": s.id.uuidString,
            "name": s.name,
            "width": s.width,
            "height": s.height,
            "fps": s.fps,
            "duration": s.timeline.duration,
            "clips": s.timeline.allClips.count,
            "renders": SequenceRenderService.renders(for: s, context: context).count,
            "updatedAt": ISO8601DateFormatter().string(from: s.updatedAt),
        ]
    }

    private static func sequenceList(context: ModelContext) throws -> [String: Any] {
        let all = try context.fetch(FetchDescriptor<SequenceProject>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))
        return MCPToolRegistry.jsonResult(all.map { summary($0, context: context) })
    }

    private static func sequenceCreate(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let count = (try? context.fetchCount(FetchDescriptor<SequenceProject>())) ?? 0
        let sequence = SequenceProject(name: (arguments["name"] as? String) ?? "Sequence \(count + 1)")
        var timeline = sequence.timeline
        if let w = intArg(arguments["width"]) { timeline.width = w }
        if let h = intArg(arguments["height"]) { timeline.height = h }
        if let f = intArg(arguments["fps"]) { timeline.fps = f }
        sequence.timeline = timeline
        context.insert(sequence)
        try context.save()
        return MCPToolRegistry.jsonResult(timelineJSON(sequence, context: context))
    }

    private static func sequenceGet(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        return MCPToolRegistry.jsonResult(timelineJSON(sequence, context: context))
    }

    private static func timelineJSON(_ sequence: SequenceProject, context: ModelContext) -> [String: Any] {
        var payload = summary(sequence, context: context)
        if let data = try? JSONEncoder().encode(sequence.timeline),
           let object = try? JSONSerialization.jsonObject(with: data) {
            payload["timeline"] = object
        }
        return payload
    }

    private static func sequenceSetTimeline(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let object = arguments["timeline"] else { throw MCPToolError.invalidArguments("missing timeline") }
        let timeline: Timeline
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            timeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            throw MCPToolError.invalidArguments("timeline is not valid: \(error.localizedDescription)")
        }
        // Re-insert every clip through the editor so the invariants hold.
        var rebuilt = Timeline(id: timeline.id, width: timeline.width, height: timeline.height, fps: timeline.fps,
                               tracks: timeline.tracks.map { Track(id: $0.id, kind: $0.kind, name: $0.name, clips: [], isMuted: $0.isMuted) },
                               backgroundHex: timeline.backgroundHex)
        for track in timeline.tracks {
            for clip in track.sortedClips {
                do { try TimelineEditor.insert(&rebuilt, clip: clip, on: track.id) } catch {
                    throw MCPToolError.invalidArguments("clip \(clip.source.displayName) on \(track.name): \(error)")
                }
            }
        }
        sequence.timeline = rebuilt
        try context.save()
        return MCPToolRegistry.jsonResult(timelineJSON(sequence, context: context))
    }

    private static func sequenceAddClip(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let sourceID = arguments["source_id"] as? String, let (prefix, uuid) = DocumentMediaResolver.parse(sourceID) else {
            throw MCPToolError.invalidArguments("missing or malformed source_id; use footage_list")
        }
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) else {
            throw MCPToolError.invalidArguments("the film is not open in a window")
        }
        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        let kind: SourceKind
        var displayName = sourceID
        switch prefix {
        case .music, .narration: kind = .audio
        case .image: kind = .image
        case .video: kind = .video
        case .remotion: kind = .remotion
        case .caption: kind = .captions
        case .imported:
            let asset = try context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == uuid })).first
            guard let asset else { throw MCPToolError.projectNotFound(sourceID) }
            kind = asset.kindEnum == .image ? .image : (asset.kindEnum == .audio ? .audio : .video)
            displayName = asset.name
        }
        if prefix != .imported {
            displayName = try footageName(prefix: prefix, uuid: uuid, fallback: sourceID, context: context)
        }
        let source = ClipSource(id: sourceID, kind: kind, displayName: displayName)

        var duration = (arguments["duration"] as? Double) ?? 0
        if duration <= 0, kind != .image {
            switch try? await resolver.resolve(source) {
            case .file(_, let natural, _)?: duration = natural ?? 0
            case .captions(let cues)?: duration = cues.map(\.end).max() ?? 0
            case nil: break
            }
        }
        if duration <= 0 { duration = FootageDragItem.defaultStillDuration }

        var timeline = sequence.timeline
        let track: Track
        if let name = arguments["track"] as? String {
            guard let found = timeline.tracks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name.uppercased() }) else {
                throw MCPToolError.invalidArguments("no track named \(name); tracks: \(timeline.tracks.map(\.name).joined(separator: ", "))")
            }
            track = found
        } else if let first = timeline.tracks.first(where: { $0.kind == Self.preferredTrackKind(for: kind) })
                    ?? timeline.tracks.first(where: { $0.kind.accepts(kind) }) {
            track = first
        } else {
            throw MCPToolError.invalidArguments("no track accepts \(kind.rawValue)")
        }
        let start = (arguments["start"] as? Double) ?? track.end
        let clip = Clip(source: source, start: start, duration: duration, inPoint: (arguments["in_point"] as? Double) ?? 0, text: kind == .captions ? .caption : nil)
        do {
            try TimelineEditor.insert(&timeline, clip: clip, on: track.id, ripple: (arguments["ripple"] as? Bool) ?? false)
        } catch {
            throw MCPToolError.invalidArguments("could not place clip on \(track.name): \(error)")
        }
        sequence.timeline = timeline
        try context.save()
        return MCPToolRegistry.jsonResult([
            "clip_id": clip.id.uuidString,
            "track": track.name,
            "start": clip.start,
            "duration": clip.duration,
            "sequence_duration": timeline.duration,
        ] as [String: Any])
    }

    /// Pictures go on a video lane, sound on an audio lane, captions on the overlay.
    private static func preferredTrackKind(for kind: SourceKind) -> TrackKind {
        switch kind {
        case .video, .image, .remotion: return .video
        case .audio: return .audio
        case .captions: return .overlay
        }
    }

    private static func footageName(prefix: DocumentMediaResolver.SourceKindPrefix, uuid: UUID, fallback: String, context: ModelContext) throws -> String {
        switch prefix {
        case .music: return try context.fetch(FetchDescriptor<GeneratedMusic>(predicate: #Predicate { $0.id == uuid })).first?.project?.name ?? fallback
        case .narration: return try context.fetch(FetchDescriptor<GeneratedNarrative>(predicate: #Predicate { $0.id == uuid })).first?.project?.name ?? fallback
        case .image: return try context.fetch(FetchDescriptor<GeneratedImage>(predicate: #Predicate { $0.id == uuid })).first?.project?.name ?? fallback
        case .video: return try context.fetch(FetchDescriptor<GeneratedVideo>(predicate: #Predicate { $0.id == uuid })).first?.project?.name ?? fallback
        case .remotion: return try context.fetch(FetchDescriptor<RemotionProject>(predicate: #Predicate { $0.id == uuid })).first?.name ?? fallback
        case .caption: return try context.fetch(FetchDescriptor<CaptionProject>(predicate: #Predicate { $0.projectUUID == uuid })).first?.name ?? fallback
        case .imported: return fallback
        }
    }

    private static func sequenceRemoveClip(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let raw = arguments["clip_id"] as? String, let clipID = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("missing clip_id")
        }
        var timeline = sequence.timeline
        if (arguments["ripple"] as? Bool) == true {
            try TimelineEditor.rippleDelete(&timeline, clipID: clipID)
        } else {
            TimelineEditor.remove(&timeline, clipID: clipID)
        }
        sequence.timeline = timeline
        try context.save()
        return MCPToolRegistry.jsonResult(["ok": true, "sequence_duration": timeline.duration] as [String: Any])
    }

    private static func sequenceRender(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) else {
            throw MCPToolError.invalidArguments("the film is not open in a window")
        }
        var options = TimelineExporter.Options()
        if let codec = arguments["codec"] as? String, codec != "h264" {
            guard codec == "none" || TimelineExporter.VideoCodec(rawValue: codec) != nil else {
                throw MCPToolError.invalidArguments("codec must be h264, hevc or none")
            }
            options.video = TimelineExporter.VideoCodec(rawValue: codec)
        }
        if let audio = arguments["audio"] as? String, audio != "aac" {
            guard audio == "none" || TimelineExporter.AudioCodec(rawValue: audio) != nil else {
                throw MCPToolError.invalidArguments("audio must be aac or none")
            }
            options.audio = TimelineExporter.AudioCodec(rawValue: audio)
        }
        if let raw = arguments["resolution"] as? String {
            guard let resolution = TimelineExporter.Resolution(rawValue: raw) else {
                throw MCPToolError.invalidArguments("resolution must be one of \(TimelineExporter.Resolution.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            options.resolution = resolution
        }
        if let raw = arguments["format"] as? String {
            guard let container = TimelineExporter.Container(rawValue: raw) else {
                throw MCPToolError.invalidArguments("format must be mp4, mov or m4a")
            }
            options.container = container
        }
        var destination = SequenceRenderDestination.film
        if let dir = arguments["output_dir"] as? String, !dir.isEmpty {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw MCPToolError.invalidArguments("output_dir must be an existing folder")
            }
            destination = .folder(URL(fileURLWithPath: dir, isDirectory: true))
        }
        let output: SequenceRenderOutput
        do {
            output = try await SequenceRenderService.render(sequence: sequence, document: document, options: options, destination: destination) { _ in }
        } catch {
            throw MCPToolError.underlying(error)
        }
        switch output {
        case .version(let render): return MCPToolRegistry.jsonResult(renderJSON(render))
        case .file(let url): return MCPToolRegistry.jsonResult(["path": url.path, "codec": options.video?.rawValue ?? "audio"] as [String: Any])
        }
    }

    private static func sequenceRenders(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        return MCPToolRegistry.jsonResult(SequenceRenderService.renders(for: sequence, context: context).map(renderJSON))
    }

    private static func renderJSON(_ r: SequenceRender) -> [String: Any] {
        [
            "id": r.id.uuidString,
            "version": r.versionNumber,
            "path": r.videoURL.path,
            "width": r.width,
            "height": r.height,
            "fps": r.fps,
            "duration": r.durationSeconds,
            "codec": r.preset,
            "createdAt": ISO8601DateFormatter().string(from: r.createdAt),
        ]
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
