import Foundation
import SwiftData

/// Caption tools.
///
/// A caption project owns an audio source, a speaker roster, and an ordered list
/// of timed captions. These tools let an MCP client transcribe audio, read and
/// correct captions, and export VTT/SRT/text.
///
/// Two deliberate shape choices, both about result size: listing captions is
/// **paginated**, and export writes a file and returns its path rather than
/// inlining the body. A one-hour transcript is hundreds of kilobytes and would
/// otherwise blow the response budget on every call.
@MainActor
enum MCPCaptionHandlers {
    static let descriptors: [MCPToolDescriptor] = [
        MCPToolDescriptor(
            name: "caption_create",
            description: "Create a caption project. Optionally attach audio immediately: pass `narrative_id` to caption an existing generated narration (timings come from the speech service, caption text stays exactly as written in the narrative), or `audio_path` for an absolute path to an audio file on disk, which is copied into app storage. Returns the caption project state.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "Display name. Defaults to 'Untitled Captions'."] as [String: Any],
                    "narrative_id": ["type": "string", "description": "Optional narrative project id whose most recent generated audio should be captioned."] as [String: Any],
                    "audio_path": ["type": "string", "description": "Optional absolute path to an audio file to import."] as [String: Any],
                    "provider": ["type": "string", "enum": ["WhisperKit", "OpenAI", "Azure", "Gemini"], "description": "Optional transcription provider override. Omit to use the app default."] as [String: Any],
                    "language": ["type": "string", "description": "Optional BCP-47 language hint (e.g. 'en-US', 'zh-CN'). Omit to auto-detect."] as [String: Any],
                    "max_speakers": ["type": "integer", "description": "Optional speaker cap for diarization (2-35). Only used by Azure and Gemini."] as [String: Any]
                ]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_transcribe",
            description: "Run transcription on a caption project's audio, replacing all existing captions. For a narrative-sourced project this aligns the narrative's own text to the audio (timings only from the speech service); otherwise it transcribes the audio directly. This can take minutes for long audio. Returns a summary including how many captions were created and any warning about degraded timings or missing speaker detection.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any]
                ],
                "required": ["caption_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_list_segments",
            description: "List a caption project's captions, paginated. Each entry has its index, start/end milliseconds, text, speaker, and word count. Use `offset`/`limit` to page; the response reports `total` and `hasMore`. Pass `include_words: true` to get per-word timings (verbose — prefer paging with a small limit).",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "offset": ["type": "integer", "description": "0-based start index. Defaults to 0."] as [String: Any],
                    "limit": ["type": "integer", "description": "Maximum entries to return. Defaults to 50, capped at 200."] as [String: Any],
                    "include_words": ["type": "boolean", "description": "Include per-word timings. Defaults to false."] as [String: Any]
                ],
                "required": ["caption_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_update_segment",
            description: "Update one caption by 0-based index. Only the fields you pass change. Editing `text` re-matches word timings to the new wording; editing `start_ms`/`end_ms` rescales them. `speaker` may be a speaker id or an existing speaker label. Returns the updated caption.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "index": ["type": "integer", "description": "0-based caption index."] as [String: Any],
                    "text": ["type": "string", "description": "New caption text."] as [String: Any],
                    "start_ms": ["type": "integer", "description": "New start time in milliseconds."] as [String: Any],
                    "end_ms": ["type": "integer", "description": "New end time in milliseconds."] as [String: Any],
                    "speaker": ["type": "string", "description": "Speaker id or label to assign."] as [String: Any]
                ],
                "required": ["caption_id", "index"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_set_speakers",
            description: "Rename or replace the speaker roster. Pass `rename` to change one label, or `labels` to replace the whole roster in order. Renaming preserves which captions are assigned to that speaker; replacing the roster reassigns captions positionally. Returns the roster.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "rename": [
                        "type": "object",
                        "description": "Rename a single speaker.",
                        "properties": [
                            "from": ["type": "string", "description": "Current label or speaker id."] as [String: Any],
                            "to": ["type": "string", "description": "New label."] as [String: Any]
                        ],
                        "required": ["from", "to"]
                    ] as [String: Any],
                    "labels": ["type": "array", "items": ["type": "string"], "description": "Replacement roster, in order."] as [String: Any]
                ],
                "required": ["caption_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_export",
            description: "Render captions to a file and return its absolute path. `format` is vtt, srt, text or json. `granularity` is sentence (one cue per caption), word (one cue per word), or word_karaoke (WebVTT only, inline word timings). Returns the path, byte size and cue count — never the file body, which can be hundreds of kilobytes.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "format": ["type": "string", "enum": ["vtt", "srt", "text", "json"], "description": "Output format. Defaults to vtt."] as [String: Any],
                    "granularity": ["type": "string", "enum": ["sentence", "word", "word_karaoke"], "description": "Cue granularity. Defaults to sentence."] as [String: Any],
                    "speaker_style": ["type": "string", "enum": ["none", "prefix", "vtt_voice_tag"], "description": "How to render speaker names. Defaults to prefix."] as [String: Any],
                    "destination": ["type": "string", "description": "Optional absolute output path. Defaults to a file in app storage."] as [String: Any]
                ],
                "required": ["caption_id"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_search_segments",
            description: "Find captions containing the given words. Matching ignores case, accents and punctuation, so 'dont' matches \"don't\". Returns matching captions with their 0-based index, times and text, plus `total` matches found. Use this instead of paging through caption_list_segments when you know roughly what you're looking for.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "query": ["type": "string", "description": "Words to look for. A caption matches when it contains any of them."] as [String: Any],
                    "limit": ["type": "integer", "description": "Maximum matches to return. Defaults to 20, capped at 100."] as [String: Any],
                    "context": ["type": "integer", "description": "Also return this many captions either side of each match. Defaults to 0, capped at 3."] as [String: Any]
                ],
                "required": ["caption_id", "query"]
            ]
        ),
        MCPToolDescriptor(
            name: "caption_propose_edits",
            description: "Propose changes to captions for the user to review. Nothing is written: the proposal appears in the app's caption assistant, where the user approves or rejects each change individually. Use this rather than caption_update_segment whenever you are acting on a user's conversational request. Each edit names a 0-based caption `index` and a `kind`: replace_text (pass `text`), split (pass `pieces`, which must contain the same words as the original — punctuation may differ), merge_with_next, or delete. Returns how many edits were accepted and which were rejected, with reasons.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "caption_id": ["type": "string", "description": "Caption project id."] as [String: Any],
                    "summary": ["type": "string", "description": "One line describing the batch, shown above the review list."] as [String: Any],
                    "edits": [
                        "type": "array",
                        "description": "The changes to propose.",
                        "items": [
                            "type": "object",
                            "properties": [
                                "index": ["type": "integer", "description": "0-based caption index."] as [String: Any],
                                "kind": ["type": "string", "enum": ["replace_text", "split", "merge_with_next", "delete"], "description": "What to do."] as [String: Any],
                                "text": ["type": "string", "description": "New text, for replace_text."] as [String: Any],
                                "pieces": ["type": "array", "items": ["type": "string"], "description": "The caption broken into lines, for split."] as [String: Any],
                                "reason": ["type": "string", "description": "Short explanation shown next to the change."] as [String: Any]
                            ],
                            "required": ["index", "kind"]
                        ] as [String: Any]
                    ] as [String: Any]
                ],
                "required": ["caption_id", "edits"]
            ]
        )
    ]

    static let toolNames: Set<String> = Set(descriptors.map(\.name))

    static func canHandle(_ name: String) -> Bool { toolNames.contains(name) }

    static func handle(
        name: String,
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        switch name {
        case "caption_create":
            return try await create(arguments: arguments, context: context)
        case "caption_transcribe":
            return try await transcribe(arguments: arguments, context: context)
        case "caption_list_segments":
            return try listSegments(arguments: arguments, context: context)
        case "caption_update_segment":
            return try updateSegment(arguments: arguments, context: context)
        case "caption_set_speakers":
            return try setSpeakers(arguments: arguments, context: context)
        case "caption_export":
            return try await export(arguments: arguments, context: context)
        case "caption_search_segments":
            return try searchSegments(arguments: arguments, context: context)
        case "caption_propose_edits":
            return try proposeEdits(arguments: arguments, context: context)
        default:
            throw MCPToolError.invalidArguments("unrecognized: \(name)")
        }
    }

    // MARK: - Tools

    private static func create(
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        // Validate everything that can fail *before* inserting, so a rejected
        // call doesn't leave an orphan project behind.
        var provider: CaptionProvider?
        if let raw = arguments["provider"] as? String {
            guard let parsed = CaptionProvider(rawValue: raw) else {
                throw MCPToolError.invalidArguments(
                    "provider must be one of: "
                    + CaptionProvider.allCases.map(\.rawValue).joined(separator: ", ")
                )
            }
            provider = parsed
        }

        var narrativeSource: (narrative: NarrativeProject, audio: GeneratedNarrative)?
        if let narrativeID = arguments["narrative_id"] as? String {
            let narrative = try MCPProjectHandlers.fetchNarrative(id: narrativeID, context: context)
            guard let latest = narrative.generatedFiles
                .sorted(by: { $0.createdAt > $1.createdAt }).first
            else {
                throw MCPToolError.invalidArguments(
                    "narrative '\(narrative.name)' has no generated audio yet"
                )
            }
            narrativeSource = (narrative, latest)
        }

        var importedPath: String?
        if narrativeSource == nil, let path = arguments["audio_path"] as? String {
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw MCPToolError.invalidArguments("no file at \(path)")
            }
            do {
                importedPath = try FileStorage.importAudio(from: url)
            } catch {
                throw MCPToolError.underlying(error)
            }
        }

        let project = CaptionProject(
            name: (arguments["name"] as? String) ?? "Untitled Captions"
        )
        project.languageHint = (arguments["language"] as? String) ?? ""
        if let maxSpeakers = intArg(arguments["max_speakers"]) {
            project.maxSpeakers = clampCaptionMaxSpeakers(maxSpeakers)
        }
        if let provider { project.provider = provider.rawValue }
        context.insert(project)

        // Attaching a narration is the timings-only path, so capture the
        // reference text now.
        if let source = narrativeSource {
            project.audioFilePath = source.audio.audioFilePath
            project.ownsAudioFile = false
            project.sourceKindEnum = .generatedNarrative
            project.sourceNarrativeID = source.audio.captionSourceID
            project.sourceNarrativeName = source.narrative.name
            project.diarizationEnabled = false
            project.speakers = CaptionReferenceBuilder.speakers(for: source.narrative)
            project.referenceUnits = CaptionReferenceBuilder.units(
                for: source.narrative, project: project
            )
        } else if let importedPath {
            project.audioFilePath = importedPath
            project.ownsAudioFile = true
            project.sourceKindEnum = .importedFile
        }

        if project.hasAudio,
           let ms = try? await AudioProbe.durationMs(of: project.audioURL) {
            project.audioDurationMs = ms
        }

        try context.save()
        return MCPToolRegistry.jsonResult(summary(project))
    }

    private static func transcribe(
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        let config: AppConfig
        do {
            config = try AppConfig.loadFromKeychain()
        } catch {
            throw MCPToolError.underlying(error)
        }

        do {
            let count: Int
            if project.isNarrativeSourced {
                count = try await CaptionTranscriptionService.alignNarrative(
                    project: project, context: context, config: config
                )
            } else {
                count = try await CaptionTranscriptionService.transcribe(
                    project: project, context: context, config: config
                )
            }
            var payload = summary(project)
            payload["createdSegments"] = count
            return MCPToolRegistry.jsonResult(payload)
        } catch {
            throw MCPToolError.underlying(error)
        }
    }

    private static func listSegments(
        arguments: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        let all = project.orderedSegments

        let offset = max(intArg(arguments["offset"]) ?? 0, 0)
        // Capped: an uncapped limit on an hour-long transcript would return
        // hundreds of KB in a single tool result.
        let limit = min(max(intArg(arguments["limit"]) ?? 50, 1), 200)
        let includeWords = (arguments["include_words"] as? Bool) ?? false

        let slice = offset < all.count
            ? Array(all[offset..<min(offset + limit, all.count)])
            : []

        let entries = slice.enumerated().map { position, segment -> [String: Any] in
            var entry: [String: Any] = [
                "index": offset + position,
                "startMs": segment.startMs,
                "endMs": segment.endMs,
                "text": segment.text,
                "speaker": project.speakerLabel(segment.speakerId),
                "wordCount": segment.words.count,
                "isEstimatedTiming": segment.isEstimatedTiming,
            ]
            if includeWords {
                entry["words"] = segment.words.map {
                    [
                        "text": $0.text,
                        "offsetMs": $0.offsetMs,
                        "durationMs": $0.durationMs,
                        "isEstimated": $0.isEstimated,
                    ] as [String: Any]
                }
            }
            return entry
        }

        return MCPToolRegistry.jsonResult([
            "captionId": project.projectUUID.uuidString,
            "total": all.count,
            "offset": offset,
            "limit": limit,
            "hasMore": offset + slice.count < all.count,
            "segments": entries,
        ])
    }

    private static func updateSegment(
        arguments: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        guard let index = intArg(arguments["index"]) else {
            throw MCPToolError.invalidArguments("missing index")
        }
        let ordered = project.orderedSegments
        guard ordered.indices.contains(index) else {
            throw MCPToolError.invalidArguments(
                "index \(index) is out of range (0..<\(ordered.count))"
            )
        }
        let segment = ordered[index]

        // Retime before re-tokenizing so word rescaling happens against the
        // final span rather than the old one.
        let newStart = intArg(arguments["start_ms"]) ?? segment.startMs
        let newEnd = intArg(arguments["end_ms"]) ?? segment.endMs
        if newStart != segment.startMs || newEnd != segment.endMs {
            guard newEnd > newStart, newStart >= 0 else {
                throw MCPToolError.invalidArguments("end_ms must be greater than start_ms")
            }
            if project.audioDurationMs > 0, newEnd > project.audioDurationMs {
                throw MCPToolError.invalidArguments(
                    "end_ms \(newEnd) exceeds the audio duration (\(project.audioDurationMs) ms)"
                )
            }
            segment.retime(toStartMs: newStart, endMs: newEnd)
        }

        if let text = arguments["text"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPToolError.invalidArguments("text must not be empty")
            }
            let previousWords = segment.words
            segment.text = trimmed
            if !previousWords.isEmpty {
                segment.retokenizeWords(preservingTimingsFrom: previousWords)
            }
        }

        if let speaker = arguments["speaker"] as? String {
            guard let resolved = resolveSpeaker(speaker, in: project) else {
                throw MCPToolError.invalidArguments(
                    "no speaker matching '\(speaker)'. Known speakers: "
                    + project.speakers.map(\.label).joined(separator: ", ")
                )
            }
            segment.speakerId = resolved
        }

        segment.isUserEdited = true
        project.updatedAt = Date()
        try context.save()

        return MCPToolRegistry.jsonResult([
            "index": index,
            "startMs": segment.startMs,
            "endMs": segment.endMs,
            "text": segment.text,
            "speaker": project.speakerLabel(segment.speakerId),
            "wordCount": segment.words.count,
        ])
    }

    private static func setSpeakers(
        arguments: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)

        if let rename = arguments["rename"] as? [String: Any] {
            guard let from = rename["from"] as? String, let to = rename["to"] as? String else {
                throw MCPToolError.invalidArguments("rename requires 'from' and 'to'")
            }
            let trimmed = to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPToolError.invalidArguments("rename 'to' must not be empty")
            }
            guard let id = resolveSpeaker(from, in: project),
                  let position = project.speakers.firstIndex(where: { $0.id == id })
            else {
                throw MCPToolError.invalidArguments("no speaker matching '\(from)'")
            }
            var speakers = project.speakers
            speakers[position].label = trimmed
            project.speakers = speakers
        } else if let labels = arguments["labels"] as? [String] {
            let cleaned = labels
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !cleaned.isEmpty else {
                throw MCPToolError.invalidArguments("labels must contain at least one name")
            }
            // Reuse existing ids positionally so captions keep their assignment.
            let existing = project.speakers
            project.speakers = cleaned.enumerated().map { index, label in
                if index < existing.count {
                    var copy = existing[index]
                    copy.label = label
                    return copy
                }
                return CaptionSpeaker(label: label, colorIndex: index)
            }
        } else {
            throw MCPToolError.invalidArguments("pass either 'rename' or 'labels'")
        }

        project.updatedAt = Date()
        try context.save()
        return MCPToolRegistry.jsonResult([
            "captionId": project.projectUUID.uuidString,
            "speakers": project.speakers.map {
                ["id": $0.id.uuidString, "label": $0.label] as [String: Any]
            },
        ])
    }

    private static func export(
        arguments: [String: Any],
        context: ModelContext
    ) async throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        guard !project.segments.isEmpty else {
            throw MCPToolError.invalidArguments(
                "this caption project has no captions yet — run caption_transcribe first"
            )
        }

        var options = CaptionExportOptions()
        if let raw = arguments["format"] as? String {
            guard let format = CaptionExportFormat(rawValue: raw) else {
                throw MCPToolError.invalidArguments("format must be one of: vtt, srt, text, json")
            }
            options.format = format
        }
        if let raw = arguments["granularity"] as? String {
            switch raw {
            case "sentence": options.granularity = .sentence
            case "word": options.granularity = .word
            case "word_karaoke": options.granularity = .wordKaraoke
            default:
                throw MCPToolError.invalidArguments(
                    "granularity must be one of: sentence, word, word_karaoke"
                )
            }
        }
        if let raw = arguments["speaker_style"] as? String {
            switch raw {
            case "none": options.speakerStyle = .none
            case "prefix": options.speakerStyle = .prefix
            case "vtt_voice_tag": options.speakerStyle = .vttVoiceTag
            default:
                throw MCPToolError.invalidArguments(
                    "speaker_style must be one of: none, prefix, vtt_voice_tag"
                )
            }
        }

        let snapshot = project.snapshot()
        let data: Data
        do {
            data = try await CaptionExporter.render(snapshot, options: options)
        } catch {
            throw MCPToolError.underlying(error)
        }

        let destination: URL
        if let path = arguments["destination"] as? String {
            destination = URL(fileURLWithPath: path)
        } else {
            destination = FileStorage.captionsDir.appendingPathComponent(
                CaptionExporter.defaultFilename(projectName: project.name, options: options)
            )
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination)
        } catch {
            throw MCPToolError.underlying(error)
        }

        let cues = CaptionExporter.cues(from: snapshot, options: options)
        // Path, not body: an hour of captions is far too large to inline.
        return MCPToolRegistry.jsonResult([
            "path": destination.path,
            "format": options.format.rawValue,
            "granularity": options.effectiveGranularity.rawValue,
            "bytes": data.count,
            "cues": cues.count,
        ])
    }

    // MARK: - Search

    /// Keyword search over the transcript.
    ///
    /// Exists so an agent with a small context window doesn't have to page
    /// through a 900-caption transcript to find the three lines it cares about.
    /// Matching goes through `CaptionTermMatching.tokens`, the same normalized
    /// form the aligner uses, so punctuation and case never cost a hit.
    private static func searchSegments(
        arguments: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        guard let query = arguments["query"] as? String,
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPToolError.invalidArguments("missing query")
        }

        let limit = min(max(intArg(arguments["limit"]) ?? 20, 1), 100)
        let padding = min(max(intArg(arguments["context"]) ?? 0, 0), 3)
        let needles = Set(CaptionTermMatching.tokens(query))
        guard !needles.isEmpty else {
            throw MCPToolError.invalidArguments("query has no searchable words")
        }

        let ordered = project.orderedSegments
        var matched: [Int] = []
        for (index, segment) in ordered.enumerated() {
            let tokens = Set(CaptionTermMatching.tokens(segment.text))
            if !tokens.isDisjoint(with: needles) { matched.append(index) }
        }

        // Neighbours are unioned in *after* the cap so a large context window
        // can't crowd out matches.
        let capped = Array(matched.prefix(limit))
        var wanted = Set(capped)
        if padding > 0 {
            for index in capped {
                for offset in 1...padding {
                    if index - offset >= 0 { wanted.insert(index - offset) }
                    if index + offset < ordered.count { wanted.insert(index + offset) }
                }
            }
        }

        let entries = wanted.sorted().map { index -> [String: Any] in
            let segment = ordered[index]
            return [
                "index": index,
                "startMs": segment.startMs,
                "endMs": segment.endMs,
                "text": segment.text,
                "speaker": project.speakerLabel(segment.speakerId),
                "isMatch": capped.contains(index),
            ]
        }

        return MCPToolRegistry.jsonResult([
            "captionId": project.projectUUID.uuidString,
            "total": matched.count,
            "returned": entries.count,
            "truncated": matched.count > capped.count,
            "segments": entries,
        ])
    }

    // MARK: - Proposals

    /// Queues changes for the user to approve, instead of applying them.
    ///
    /// This is the only caption-mutating surface offered to a command-line
    /// agent. `caption_update_segment` writes immediately, which is right for a
    /// scripted workflow but wrong for a conversational one — an agent acting on
    /// "fix the spelling" should not be able to rewrite a transcript unattended.
    /// The proposal lands in the caption assistant, where each change is
    /// approved individually.
    private static func proposeEdits(
        arguments: [String: Any],
        context: ModelContext
    ) throws -> [String: Any] {
        let project = try captionProject(from: arguments, context: context)
        guard let raw = arguments["edits"] as? [[String: Any]], !raw.isEmpty else {
            throw MCPToolError.invalidArguments("edits must be a non-empty array")
        }

        let transcript = project.snapshot()
        let ordered = transcript.segments

        var operations: [CaptionEditOperation] = []
        var reasons: [UUID: String] = [:]
        var rejected: [[String: Any]] = []

        func reject(_ index: Any?, _ why: String) {
            rejected.append(["index": index ?? NSNull(), "reason": why])
        }

        for edit in raw {
            guard let index = intArg(edit["index"]) else {
                reject(edit["index"], "missing index")
                continue
            }
            guard ordered.indices.contains(index) else {
                reject(index, "index is out of range (0..<\(ordered.count))")
                continue
            }
            guard let kind = edit["kind"] as? String else {
                reject(index, "missing kind")
                continue
            }
            let segment = ordered[index]

            switch kind {
            case "replace_text":
                guard let text = (edit["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    reject(index, "replace_text needs a non-empty text")
                    continue
                }
                operations.append(.replaceText(segment: segment.id, newText: text))

            case "split":
                let pieces = ((edit["pieces"] as? [Any])?.compactMap { $0 as? String } ?? [])
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard pieces.count >= 2 else {
                    reject(index, "split needs at least two pieces")
                    continue
                }
                operations.append(.split(segment: segment.id, pieces: pieces))

            case "merge_with_next":
                guard index + 1 < ordered.count else {
                    reject(index, "this is the last caption, so there is nothing to merge into it")
                    continue
                }
                operations.append(.merge(segment: segment.id, withNext: ordered[index + 1].id))

            case "delete":
                operations.append(.delete(segment: segment.id))

            default:
                reject(index, "kind must be one of: replace_text, split, merge_with_next, delete")
                continue
            }

            if let reason = edit["reason"] as? String, !reason.isEmpty {
                reasons[segment.id] = reason
            }
        }

        guard !operations.isEmpty else {
            return MCPToolRegistry.jsonResult([
                "captionId": project.projectUUID.uuidString,
                "accepted": 0,
                "rejected": rejected,
                "message": "No edits could be applied to this transcript.",
            ])
        }

        let summaryText = (arguments["summary"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // A batch task running against this project judges its own proposals —
        // a split run may not change words. Otherwise this is a conversational
        // edit: the user asked for it in their own words, so validation checks
        // applicability only.
        let batchPolicy = CaptionProposalInbox.policy(for: project.projectUUID)
        let proposal = CaptionProposalBuilder.build(
            operations: operations,
            transcript: transcript,
            terms: project.usableTerms,
            policy: batchPolicy ?? .free,
            maxRunes: CaptionSettings.shared.maxCueRunes,
            summary: summaryText.isEmpty
                ? "\(operations.count) change\(operations.count == 1 ? "" : "s") to review"
                : summaryText,
            engine: CaptionProposalInbox.engineLabel(for: project.projectUUID),
            reasons: reasons
        )

        // Claimed by a batch task: this call *is* that task's result, so hand it
        // over rather than posting it to the assistant window, where nothing is
        // waiting for it.
        if CaptionProposalInbox.deliver(proposal, for: project.projectUUID) {
            return MCPToolRegistry.jsonResult([
                "captionId": project.projectUUID.uuidString,
                "accepted": proposal.items.count,
                "rejected": rejected,
                "message": "Queued for the user to review.",
            ])
        }

        // Surfaced in the assistant window: a persisted row so it survives the
        // window being closed, plus the live pending proposal so the review
        // sheet opens if that window is already up.
        let message = CaptionAssistantMessage(
            role: .assistant,
            content: proposal.summary,
            kind: .proposal,
            proposalJSON: proposal.encodedJSON()
        )
        message.project = project
        context.insert(message)
        project.assistantMessages.append(message)
        try context.save()

        CaptionAssistantController.shared.setPendingProposal(
            proposal,
            for: project.projectUUID
        )

        return MCPToolRegistry.jsonResult([
            "captionId": project.projectUUID.uuidString,
            "accepted": proposal.items.count,
            "flagged": proposal.items.count - proposal.okCount,
            "rejected": rejected,
            "message": "Sent to the user for review. Nothing has been changed yet.",
            "items": proposal.items.map { item -> [String: Any] in
                [
                    "index": item.displayIndex - 1,
                    "before": item.before,
                    "after": item.after,
                    "ok": item.verdict.isOK,
                    "note": item.verdict.message,
                ]
            },
        ])
    }

    // MARK: - Helpers

    /// Compact project state. Never includes the caption list — use
    /// `caption_list_segments` for that.
    static func summary(_ project: CaptionProject) -> [String: Any] {
        var out: [String: Any] = [
            "id": project.projectUUID.uuidString,
            "name": project.name,
            "source": project.sourceKindEnum.rawValue,
            "hasAudio": project.hasAudio,
            "audioDurationMs": project.audioDurationMs,
            "segmentCount": project.segments.count,
            "provider": project.provider.isEmpty ? "default" : project.provider,
            "language": project.languageHint,
            "diarizationEnabled": project.diarizationEnabled,
            "maxSpeakers": project.maxSpeakers,
            "speakers": project.speakers.map {
                ["id": $0.id.uuidString, "label": $0.label] as [String: Any]
            },
            "createdAt": isoDate(project.createdAt),
            "updatedAt": isoDate(project.updatedAt),
        ]
        if project.isNarrativeSourced {
            out["narrativeName"] = project.sourceNarrativeName
            out["referenceParagraphs"] = project.referenceUnits.count
            out["alignmentQuality"] = project.alignmentQualityEnum.rawValue
            out["alignmentMatchRatio"] = project.alignmentMatchRatio
        }
        // The glossary is small and changes what a correction should look like,
        // so it rides along rather than needing a second call.
        if !project.usableTerms.isEmpty {
            out["terms"] = project.usableTerms.map { term -> [String: Any] in
                var entry: [String: Any] = ["text": term.text]
                if !term.note.isEmpty { entry["note"] = term.note }
                if !term.variants.isEmpty { entry["variants"] = term.variants }
                return entry
            }
        }
        if !project.warning.isEmpty { out["warning"] = project.warning }
        if !project.lastProviderName.isEmpty { out["lastProvider"] = project.lastProviderName }
        if let date = project.lastTranscribedAt { out["lastTranscribedAt"] = isoDate(date) }
        return out
    }

    static func fetchCaption(id: String, context: ModelContext) throws -> CaptionProject {
        guard let uuid = UUID(uuidString: id) else {
            throw MCPToolError.invalidArguments("caption_id is not a valid id: \(id)")
        }
        let descriptor = FetchDescriptor<CaptionProject>(
            predicate: #Predicate { $0.projectUUID == uuid }
        )
        guard let project = try context.fetch(descriptor).first else {
            throw MCPToolError.projectNotFound(id)
        }
        return project
    }

    private static func captionProject(
        from arguments: [String: Any],
        context: ModelContext
    ) throws -> CaptionProject {
        guard let id = arguments["caption_id"] as? String else {
            throw MCPToolError.invalidArguments("missing caption_id")
        }
        return try fetchCaption(id: id, context: context)
    }

    /// Accepts either a speaker id or a label, since an agent is far more likely
    /// to have the label to hand.
    private static func resolveSpeaker(_ raw: String, in project: CaptionProject) -> UUID? {
        if let uuid = UUID(uuidString: raw), project.speakers.contains(where: { $0.id == uuid }) {
            return uuid
        }
        return project.speakers.first {
            $0.label.compare(raw, options: .caseInsensitive) == .orderedSame
        }?.id
    }

    private static func intArg(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? Double { return Int(n) }
        return nil
    }

    private static func isoDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
