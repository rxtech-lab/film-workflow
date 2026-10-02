import AVFoundation
import AppKit
import Foundation
import SwiftData
import UniformTypeIdentifiers
import VideoEditorCore

/// Sequences — the film's timelines — and their tracks and clips, for agents.
/// Footage itself is listed by `MCPLibraryHandlers.footage_list`; the
/// `sourceId` it returns is what goes on a track here.
@MainActor
enum MCPSequenceHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "sequence_list",
            description: "The film's sequences (timelines) with size, frame rate, duration, clip count and how many renders each has. Sequences also appear in footage_list as kind `sequence`; their id is the `sequence_id` these tools take.",
            inputSchema: ["type": "object", "properties": [String: Any](), "additionalProperties": false]
        ),
        MCPToolDescriptor(
            name: "sequence_create",
            description: "Create a sequence in the library. Returns its id and the default tracks (T1 overlay, V1 video, A1/A2 audio). Rename or resize it later with footage_update.",
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
            name: "sequence_add_track",
            description: "Add an empty video, audio, caption or overlay track to a sequence without changing existing tracks or clips. Inspect sequence_get first and reuse a suitable track when possible; add a track when footage needs a separate layer or overlapping audio. Uses the editor's default naming and track order (V2, A3, C1, T2, etc.). Returns track_id, track (name) and kind; pass track_id as sequence_add_clip's `track` argument.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "kind": ["type": "string", "enum": TrackKind.allCases.filter { $0 != .zoom }.map(\.rawValue), "description": "video for pictures, audio for sound, caption for captions, overlay for captions or images. Zoom lanes belong to a screen recording and are made with it."] as [String: Any],
                ],
                "required": ["sequence_id", "kind"],
                "additionalProperties": false,
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_reorder_tracks",
            description: "Reorder a sequence's whole tracks from top to bottom. Read sequence_get first, then supply every track id exactly once in the desired order. Preserves track names, clips, timing, mute settings and transitions. Higher video/overlay tracks appear above lower picture tracks in preview and export; moving audio tracks changes their layout without changing the mix.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "track_ids": ["type": "array", "items": ["type": "string"], "uniqueItems": true,
                                  "description": "Every track UUID from sequence_get, in the desired top-to-bottom order."] as [String: Any],
                ],
                "required": ["sequence_id", "track_ids"],
                "additionalProperties": false,
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_add_clip",
            description: "Put one take on a track as a clip. `source_id` is a `sourceId` from footage_list or footage_get — the newest take of an item, or a specific one with include_versions. Video, images and Remotion compositions go on a `video` track, music and narration on an `audio` track, captions on the `overlay` track. Omit `start` to append after the track's last clip; omit `duration` to use the take's natural length (stills default to 5 s).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "source_id": ["type": "string", "description": "A `sourceId` from footage_list or footage_get, e.g. `video:<uuid>`, `music:<uuid>`, `remotion:<uuid>`, `caption:<uuid>`, `imported:<uuid>`."] as [String: Any],
                    "track": ["type": "string", "description": "Track name such as V1, A1, T1, or a track id from sequence_get or sequence_add_track. Defaults to the first track that accepts the footage. Use sequence_add_track first when a separate track is needed."] as [String: Any],
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
            name: "sequence_find_gaps",
            description: "Empty stretches on each track of a sequence — before the first clip, between clips, and after the last clip up to the sequence end — with the clips on either side and the other lanes covering them. Disabled clips count as empty. Each gap lists `issues`: `blank_screen` (no picture lane covers part of it, so the background shows between shots), `flash` (a few frames between clips — almost always a misplaced clip), `breaks_transition` (it separates two clips a transition joins, so the transition is dropped) and `silence` (nothing else is audible across an audio gap). Also returns `blank_picture`, every stretch of the sequence with no picture at all. Gaps on caption and overlay lanes are normal and carry no issues. Run it before rendering a finished cut.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "min_duration": ["type": "number", "description": "Leave out gaps shorter than this many seconds. Default 0: every gap."] as [String: Any],
                    "issues_only": ["type": "boolean", "description": "Only return gaps that have an issue. Default false."] as [String: Any],
                ],
                "required": ["sequence_id"],
                "additionalProperties": false,
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_close_gap",
            description: "Fill one gap sequence_find_gaps reported. `ripple` pulls every later clip on that track left by the gap's length (linked clips follow; other tracks stay put, so re-align music, captions or overlays timed to them). `extend_previous` lengthens the clip before the gap and `extend_next` starts the clip after it earlier, each only as far as its media allows — stills can stretch freely. Returns the track's remaining gaps; a clip that ran out of media leaves the rest open.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "track": ["type": "string", "description": "Track name such as V1, or a track id from sequence_find_gaps."] as [String: Any],
                    "at": ["type": "number", "description": "A time inside the gap, in seconds; its `start` works."] as [String: Any],
                    "fill": ["type": "string", "enum": TimelineEditor.GapFill.allCases.map(\.rawValue)] as [String: Any],
                ],
                "required": ["sequence_id", "track", "at", "fill"],
                "additionalProperties": false,
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_render",
            description: "Render a sequence, by default as a new mp4 version kept inside the film (footage_get on the sequence lists them). Remotion clips whose source changed since their last render are rendered first. Slow: minutes for long sequences.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "sequence_id": ["type": "string"] as [String: Any],
                    "codec": ["type": "string", "enum": ["h264", "hevc", "none"], "description": "Video codec; `none` exports audio only. Default h264."] as [String: Any],
                    "audio": ["type": "string", "enum": ["aac", "none"], "description": "Audio codec; `none` drops every audio track. Default aac."] as [String: Any],
                    "resolution": ["type": "string", "enum": TimelineExporter.Resolution.allCases.map(\.rawValue), "description": "Longest edge of the picture, aspect kept. Default source."] as [String: Any],
                    "format": ["type": "string", "enum": TimelineExporter.Container.allCases.map(\.rawValue), "description": "Container. Audio-only always writes m4a. Default mp4."] as [String: Any],
                    "output_dir": ["type": "string", "description": "Absolute folder path. When given the file is written there as `<sequence name>.<ext>` and is not kept as a film version."] as [String: Any],
                    "captions": ["type": "string", "enum": ["burn_in", "embedded", "sidecar", "none"], "description": "How caption clips on the timeline are delivered: drawn into the picture, as subtitle tracks inside the movie, as .srt/.vtt files beside it, or left out. Default burn_in. Ignored for audio-only renders and when no caption clip is on the timeline."] as [String: Any],
                    "caption_languages": ["type": "array", "items": ["type": "string"] as [String: Any], "description": "BCP-47 codes; an empty string is the original transcript. For embedded and sidecar, one track or file per entry. For burn_in, the first entry is the language drawn. Default [\"\"]. Each must be the original or a translation present on the caption clips."] as [String: Any],
                    "caption_bilingual": ["type": "boolean", "description": "burn_in only: draw the original above the chosen translation. Default false."] as [String: Any],
                    "caption_sidecar_format": ["type": "string", "enum": ["srt", "vtt"], "description": "File type for sidecar or caption_files. Default srt."] as [String: Any],
                    "caption_files": ["type": "boolean", "description": "Also write one .srt/.vtt file per caption_languages entry beside the movie, alongside burn_in, embedded or none — e.g. burn in the original and ship translations as files. Default false; implied by sidecar."] as [String: Any],
                ],
                "required": ["sequence_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "sequence_renders",
            description: "The rendered versions of a sequence, newest first, with file paths on disk.",
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
        case "sequence_list": return try sequenceList(context: context)
        case "sequence_create": return try sequenceCreate(arguments, context: context)
        case "sequence_get": return try sequenceGet(arguments, context: context)
        case "sequence_set_timeline": return try sequenceSetTimeline(arguments, context: context)
        case "sequence_add_track": return try sequenceAddTrack(arguments, context: context)
        case "sequence_reorder_tracks": return try sequenceReorderTracks(arguments, context: context)
        case "sequence_add_clip": return try await sequenceAddClip(arguments, context: context)
        case "sequence_remove_clip": return try sequenceRemoveClip(arguments, context: context)
        case "sequence_find_gaps": return try sequenceFindGaps(arguments, context: context)
        case "sequence_close_gap": return try sequenceCloseGap(arguments, context: context)
        case "sequence_render": return try await sequenceRender(arguments, context: context)
        case "sequence_renders": return try sequenceRenders(arguments, context: context)
        default: throw MCPToolError.invalidArguments("unknown tool \(name)")
        }
    }

    // MARK: - Sequences

    private static func fetchSequence(_ arguments: [String: Any], context: ModelContext) throws -> SequenceProject {
        guard let raw = arguments["sequence_id"] as? String, let id = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("missing or malformed sequence_id")
        }
        guard let sequence = try context.fetch(FetchDescriptor<SequenceProject>(predicate: #Predicate { $0.id == id })).first else {
            throw MCPToolError.notFound(raw)
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

    static func timelineJSON(_ sequence: SequenceProject, context: ModelContext) -> [String: Any] {
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
                               tracks: timeline.tracks.map { Track(id: $0.id, kind: $0.kind, name: $0.name, clips: [], isMuted: $0.isMuted, isEnabled: $0.isEnabled) },
                               backgroundHex: timeline.backgroundHex)
        for track in timeline.tracks {
            for var clip in track.sortedClips {
                // Recompute the kind from the id rather than trusting the agent's
                // JSON. Zoom clips and ids we don't own keep what they were sent.
                if let (prefix, uuid) = DocumentMediaResolver.parse(clip.source.id), prefix != .recordingZoom {
                    let kind = try canonicalKind(prefix: prefix, uuid: uuid, sourceID: clip.source.id, context: context)
                    if kind != clip.source.kind {
                        clip.source = ClipSource(id: clip.source.id, kind: kind, displayName: clip.source.displayName)
                    }
                }
                do { try TimelineEditor.insert(&rebuilt, clip: clip, on: track.id) } catch {
                    throw MCPToolError.invalidArguments("clip \(clip.source.displayName) on \(track.name): \(error)")
                }
            }
        }
        rebuilt.transitions = timeline.transitions
        try rebuilt.validateModifiers(requireDefinitions: true)
        let previous = sequence.timeline
        sequence.timeline = rebuilt
        try context.save()
        focus(sequence: sequence, previous: previous, context: context)
        return MCPToolRegistry.jsonResult(timelineJSON(sequence, context: context))
    }

    private static func sequenceAddTrack(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        // A zoom lane belongs to the recording that made it, so it is not a
        // lane an agent adds on its own.
        guard let raw = arguments["kind"] as? String, let kind = TrackKind(rawValue: raw), kind != .zoom else {
            throw MCPToolError.invalidArguments("kind must be video, audio, caption or overlay")
        }
        var timeline = sequence.timeline
        let trackID = TimelineEditor.addTrack(&timeline, kind: kind)
        let track = timeline.tracks.first { $0.id == trackID }!
        sequence.timeline = timeline
        try context.save()
        return MCPToolRegistry.jsonResult([
            "sequence_id": sequence.id.uuidString,
            "track_id": trackID.uuidString,
            "track": track.name,
            "kind": track.kind.rawValue,
        ])
    }

    private static func sequenceReorderTracks(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let raw = arguments["track_ids"] as? [String] else {
            throw MCPToolError.invalidArguments("track_ids must list every track UUID from sequence_get in top-to-bottom order")
        }
        let ids = raw.compactMap(UUID.init(uuidString:))
        guard ids.count == raw.count else { throw MCPToolError.invalidArguments("track_ids contains a malformed UUID") }
        var timeline = sequence.timeline
        do { try TimelineEditor.reorderTracks(&timeline, trackIDs: ids) } catch {
            throw MCPToolError.invalidArguments(error.localizedDescription)
        }
        sequence.timeline = timeline
        try context.save()
        return MCPToolRegistry.jsonResult(timelineJSON(sequence, context: context))
    }

    /// The kind a source id implies. The id is the truth: an agent-supplied
    /// kind that disagrees (a `remotion:` clip sent as `video`) would skip the
    /// Remotion preview and leave the clip on a "Not rendered yet" slate.
    private static func canonicalKind(prefix: DocumentMediaResolver.SourceKindPrefix, uuid: UUID, sourceID: String, context: ModelContext) throws -> SourceKind {
        switch prefix {
        case .music, .narration: return .audio
        case .image: return .image
        case .video: return .video
        case .screenRecording: return try RecordingTimelineService.resolve(id: uuid, context: context).1.sourceKind
        case .remotion: return .remotion
        case .caption: return .captions
        case .recordingZoom: throw MCPToolError.notFound(sourceID)
        case .imported:
            let asset = try context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == uuid })).first
            guard let asset else { throw MCPToolError.notFound(sourceID) }
            return asset.kindEnum == .image ? .image : (asset.kindEnum == .audio ? .audio : .video)
        }
    }

    private static func sequenceAddClip(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let sourceID = arguments["source_id"] as? String, let (prefix, uuid) = DocumentMediaResolver.parse(sourceID) else {
            throw MCPToolError.invalidArguments("missing or malformed source_id; use the sourceId from footage_list")
        }
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) ?? MarketplaceAuthoringService.shared.document(forContainer: context.container) else {
            throw MCPToolError.invalidArguments("the film is not open in a window")
        }
        if prefix == .screenRecording, let take = try? RecordingTimelineService.take(id: uuid, context: document.container.mainContext) {
            let ids = try RecordingTimelineService.insert(take: take, into: sequence, at: arguments["start"] as? Double ?? sequence.timeline.duration, undoManager: NSApp.keyWindow?.undoManager); try context.save(); return MCPToolRegistry.jsonResult(["clipIDs": ids.map(\.uuidString)])
        }
        let resolver = DocumentMediaResolver(document: document, width: sequence.width, height: sequence.height, fps: sequence.fps)
        // Zoom clips come with their recording; there is nothing to add on its own.
        if prefix == .recordingZoom { throw MCPToolError.notFound(sourceID) }
        let kind = try canonicalKind(prefix: prefix, uuid: uuid, sourceID: sourceID, context: context)
        var displayName = sourceID
        if prefix == .imported {
            displayName = try context.fetch(FetchDescriptor<ImportedAsset>(predicate: #Predicate { $0.id == uuid })).first?.name ?? sourceID
        } else {
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
        document.focusTimeline(sequenceID: sequence.id, clipID: clip.id, time: clip.start)
        return MCPToolRegistry.jsonResult([
            "clip_id": clip.id.uuidString,
            "track": track.name,
            "start": clip.start,
            "duration": clip.duration,
            "sequence_duration": timeline.duration,
        ] as [String: Any])
    }

    /// Moves the playhead of any window showing this film to whatever the edit
    /// just changed, so the user can watch the agent work rather than seeing a
    /// timeline rearrange itself under a stationary playhead.
    private static func focus(sequence: SequenceProject, previous: Timeline?, context: ModelContext) {
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) else { return }
        guard let target = SequenceProject.focusTarget(before: previous, after: sequence.timeline) else {
            document.focusTimeline(sequenceID: sequence.id, time: 0)
            return
        }
        document.focusTimeline(sequenceID: sequence.id, clipID: target.clipID, time: target.start)
    }

    /// Pictures go on a video lane, sound on an audio lane, captions on a
    /// caption lane — falling back to an overlay lane when the sequence has
    /// none, since those take captions too.
    private static func preferredTrackKind(for kind: SourceKind) -> TrackKind {
        switch kind {
        case .video, .image, .remotion: return .video
        case .audio: return .audio
        case .captions: return .caption
        case .zoom: return .zoom
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
        case .screenRecording: return try RecordingTimelineService.resolve(id: uuid, context: context).1.name
        case .recordingZoom: return "Zoom"
        }
    }

    private static func sequenceRemoveClip(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let raw = arguments["clip_id"] as? String, let clipID = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments("missing clip_id")
        }
        var timeline = sequence.timeline
        let removedStart = timeline.clip(id: clipID)?.start
        if (arguments["ripple"] as? Bool) == true {
            try TimelineEditor.rippleDelete(&timeline, clipID: clipID)
        } else {
            TimelineEditor.remove(&timeline, clipID: clipID)
        }
        sequence.timeline = timeline
        try context.save()
        if let removedStart, let document = ProjectDocumentController.shared.document(forContainer: context.container) {
            document.focusTimeline(sequenceID: sequence.id, clipID: nil, time: removedStart)
        }
        return MCPToolRegistry.jsonResult(["ok": true, "sequence_duration": timeline.duration] as [String: Any])
    }

    // MARK: - Gaps

    private static func sequenceFindGaps(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        let timeline = sequence.timeline
        let minimum = max(0, (arguments["min_duration"] as? Double) ?? 0)
        let issuesOnly = (arguments["issues_only"] as? Bool) ?? false
        let reports = TimelineGapAnalyzer.analyze(timeline, minimumDuration: minimum)
        let tracks: [[String: Any]] = reports.compactMap { report in
            guard let track = timeline[trackID: report.trackID] else { return nil }
            let gaps = issuesOnly ? report.gaps.filter { !$0.issues.isEmpty } : report.gaps
            if issuesOnly, gaps.isEmpty { return nil }
            return trackGapsJSON(track, gaps: gaps, timeline: timeline)
        }
        let blank = TimelineGapAnalyzer.blankPicture(timeline)
        let issueCount = reports.flatMap(\.gaps).filter { !$0.issues.isEmpty }.count
        return MCPToolRegistry.jsonResult([
            "sequence_id": sequence.id.uuidString,
            "duration": timeline.duration,
            "fps": timeline.fps,
            "gaps_with_issues": issueCount,
            "blank_picture": blank.map { ["start": $0.lowerBound, "end": $0.upperBound, "duration": $0.upperBound - $0.lowerBound] },
            "tracks": tracks,
        ] as [String: Any])
    }

    private static func sequenceCloseGap(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let name = arguments["track"] as? String else { throw MCPToolError.invalidArguments("missing track") }
        guard let at = arguments["at"] as? Double else { throw MCPToolError.invalidArguments("missing at") }
        guard let raw = arguments["fill"] as? String, let fill = TimelineEditor.GapFill(rawValue: raw) else {
            throw MCPToolError.invalidArguments("fill must be \(TimelineEditor.GapFill.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        var timeline = sequence.timeline
        guard let track = timeline.tracks.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString == name.uppercased() }) else {
            throw MCPToolError.invalidArguments("no track named \(name); tracks: \(timeline.tracks.map(\.name).joined(separator: ", "))")
        }
        let gap: TimelineGap
        do {
            gap = try TimelineEditor.closeGap(&timeline, trackID: track.id, at: at, fill: fill)
        } catch TimelineEditError.unsupportedOperation {
            throw MCPToolError.invalidArguments("no gap on \(track.name) at \(at)s that \(raw) can fill: ripple needs a clip after the gap, extend_previous a clip before it, extend_next a clip after it, and the clip must allow trimming")
        } catch {
            throw MCPToolError.invalidArguments("could not close the gap on \(track.name): \(error.localizedDescription)")
        }
        let previous = sequence.timeline
        sequence.timeline = timeline
        try context.save()
        focus(sequence: sequence, previous: previous, context: context)
        let remaining = TimelineGapAnalyzer.analyze(timeline).first { $0.trackID == track.id }?.gaps ?? []
        var result = trackGapsJSON(timeline[trackID: track.id] ?? track, gaps: remaining, timeline: timeline)
        result["closed"] = ["start": gap.start, "end": gap.end, "fill": fill.rawValue] as [String: Any]
        result["sequence_duration"] = timeline.duration
        return MCPToolRegistry.jsonResult(result)
    }

    private static func trackGapsJSON(_ track: Track, gaps: [TimelineGap], timeline: Timeline) -> [String: Any] {
        let clipName: (UUID?) -> Any = { id in id.flatMap { timeline.clip(id: $0)?.source.displayName } ?? NSNull() }
        let trackName: (UUID) -> String = { id in timeline[trackID: id]?.name ?? id.uuidString }
        return [
            "track_id": track.id.uuidString,
            "track": track.name,
            "kind": track.kind.rawValue,
            "gaps": gaps.map { gap in
                [
                    "start": gap.start,
                    "end": gap.end,
                    "duration": gap.duration,
                    "frames": Int((gap.duration * Double(timeline.fps)).rounded()),
                    "position": gap.position.rawValue,
                    "previous_clip_id": gap.previousClipID?.uuidString ?? NSNull(),
                    "previous_clip": clipName(gap.previousClipID),
                    "next_clip_id": gap.nextClipID?.uuidString ?? NSNull(),
                    "next_clip": clipName(gap.nextClipID),
                    "covered_by": gap.coveredBy.map(trackName),
                    "uncovered": gap.uncovered.map { ["start": $0.lowerBound, "end": $0.upperBound] },
                    "issues": gap.issues.map(\.rawValue),
                ] as [String: Any]
            },
        ]
    }

    private static func sequenceRender(_ arguments: [String: Any], context: ModelContext) async throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        guard let document = ProjectDocumentController.shared.document(forContainer: context.container) ?? MarketplaceAuthoringService.shared.document(forContainer: context.container) else {
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
        let captions = try captionRequest(arguments, options: &options, sequence: sequence, context: context)
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
            output = try await SequenceRenderService.render(sequence: sequence, document: document, options: options, captions: captions, destination: destination) { _ in }
        } catch {
            throw MCPToolError.underlying(error)
        }
        switch output {
        case .version(let render):
            var json = renderJSON(render)
            json["captions"] = options.captions.rawValue
            return MCPToolRegistry.jsonResult(json)
        case .file(let url, let captionFiles):
            return MCPToolRegistry.jsonResult([
                "path": url.path,
                "codec": options.video?.rawValue ?? "audio",
                "captions": options.captions.rawValue,
                "caption_files": captionFiles.map(\.path),
            ] as [String: Any])
        }
    }

    /// Reads the caption arguments of `sequence_render` into `options.captions`
    /// and a `CaptionRenderRequest`, rejecting deliveries and languages the
    /// sequence cannot supply.
    static func captionRequest(_ arguments: [String: Any], options: inout TimelineExporter.Options, sequence: SequenceProject, context: ModelContext) throws -> CaptionRenderRequest {
        if let raw = arguments["captions"] as? String {
            let deliveries: [String: TimelineExporter.CaptionDelivery] = ["burn_in": .burnIn, "embedded": .embedded, "sidecar": .sidecar, "none": .none]
            guard let delivery = deliveries[raw] else {
                throw MCPToolError.invalidArguments("captions must be burn_in, embedded, sidecar or none")
            }
            options.captions = delivery
        }
        var request = CaptionRenderRequest()
        if let languages = arguments["caption_languages"] as? [String], !languages.isEmpty {
            let available = SequenceCaptionSources.availableLanguages(in: sequence, context: context)
            if let missing = languages.first(where: { !available.contains($0) }) {
                let choices = available.map { $0.isEmpty ? "\"\" (original)" : $0 }.joined(separator: ", ")
                throw MCPToolError.invalidArguments("caption language \(missing) is not on the timeline's caption clips; choose from \(choices)")
            }
            request.trackLanguages = languages
            request.burnInLanguage = languages[0]
        }
        if let bilingual = arguments["caption_bilingual"] as? Bool { request.burnInBilingual = bilingual }
        if let files = arguments["caption_files"] as? Bool, files {
            request.savesFiles = true
            request.fileLanguages = request.trackLanguages
        }
        if let raw = arguments["caption_sidecar_format"] as? String {
            guard let format = CaptionExportFormat(rawValue: raw), format.isSidecar else {
                throw MCPToolError.invalidArguments("caption_sidecar_format must be srt or vtt")
            }
            request.sidecarFormat = format
        }
        return request
    }

    private static func sequenceRenders(_ arguments: [String: Any], context: ModelContext) throws -> [String: Any] {
        let sequence = try fetchSequence(arguments, context: context)
        return MCPToolRegistry.jsonResult(SequenceRenderService.renders(for: sequence, context: context).map(renderJSON))
    }

    static func renderJSON(_ r: SequenceRender) -> [String: Any] {
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
            "caption_files": r.captionFileURLs.map(\.path),
        ]
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
