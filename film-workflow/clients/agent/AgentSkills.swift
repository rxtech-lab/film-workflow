import Foundation
import RxAgentSDK

/// The agent's domain know-how, one `Skill` per job the app does.
///
/// Each skill is a named block of instructions the SDK renders into the
/// system prompt under a "## Skill:" heading with a one-line "use this when"
/// description, so the model can tell which applies. They carry no tools of
/// their own: every tool is advertised over MCP with its real schema, and the
/// `tool` closure spells a name the way the current engine will see it
/// (`mcp__film_workflow__footage_list` for a CLI agent, bare otherwise).
/// `AgentPrompts` adds a skill only when the tools it talks about are offered.
extension Skill {

    /// Putting takes on a timeline and rendering it.
    static func sequenceAssembly(tool: (String) -> String) -> Skill {
        Skill(
            name: "Assembling a sequence",
            description: "Use when the user wants footage on a timeline: build, arrange, trim, replace or render a cut.",
            instructions: """
                - Start from \(tool("footage_list")). Each row's `sourceId` is the item's \
                newest take; pass `include_versions` to pick an older one. Sequences are \
                in the same list as kind `sequence`, and \(tool("sequence_list")) gives \
                their sizes and clip counts.
                - Create a sequence with \(tool("sequence_create")) only when the film has \
                none or the user asks for another. Otherwise read the one they mean with \
                \(tool("sequence_get")) before changing it, so you place clips relative \
                to what is already there.
                - \(tool("sequence_add_clip")) places one take: pictures (video, images, \
                Remotion) on V1, sound (music, narration) on A1 or A2, captions on T1. \
                Omit `start` to append after the last clip on that track; pass `ripple` \
                to make room in the middle. Stills default to 5 seconds — pass \
                `duration` for a different length. Clips on one track cannot overlap.
                - For a wholesale re-arrangement, take the JSON from \
                \(tool("sequence_get")), edit it, and write it back with \
                \(tool("sequence_set_timeline")). Use \(tool("sequence_remove_clip")) \
                with `ripple` to close the gap a removed clip leaves.
                - A Remotion composition needs no render before it goes on the \
                timeline; \(tool("sequence_render")) renders changed compositions first. \
                Rendering takes minutes on a long cut, so say what you are about to \
                render, then report the version number or output path when it is done.
                - Caption clips are drawn into the picture at render time by default; \
                the `captions` and `caption_languages` options switch to embedded \
                subtitle tracks or sidecar files, and pick which language is drawn.
                """
        )
    }

    /// Creating and regenerating footage items.
    static func footageGeneration(tool: (String) -> String, offered: Set<String>) -> Skill {
        let generators = [
            ("music", "music_generate"), ("narration", "narration_generate"),
            ("image", "image_generate"), ("video", "video_generate"),
        ].filter { offered.contains($0.1) }
        let generatorList = generators.map { "\($0.0) → \(tool($0.1))" }.joined(separator: ", ")
        return Skill(
            name: "Generating footage",
            description: "Use when the user wants new music, narration, images or video, or wants an existing item regenerated with different settings.",
            instructions: """
                - Reuse the item the user is iterating on; \(tool("footage_create")) is \
                for something new. Set its parameters with \(tool("footage_update")) — \
                the fields each kind accepts are in that tool's description — then run \
                the kind's generator: \(generatorList).
                - Every run adds a take and overwrites nothing. The newest take becomes \
                the one the library drags, so after generating, the item is ready for \
                \(tool("sequence_add_clip")) with the `sourceId` the generator returns.
                - \(tool("video_generate")) blocks for minutes. If it times out, check \
                \(tool("video_job_status")) and collect the result with \
                \(tool("video_resume")); never start a second run for the same request, \
                it bills twice.
                - A narration item is multi-speaker text-to-speech: its speakers and \
                paragraphs are fields on the item, and the podcast_* tools edit the same \
                paragraphs line by line. Captions for a narration come from \
                \(tool("caption_create")) with `narration_id`, which keeps the words \
                exactly as written.
                - Generation spends the user's credits or provider keys. Do not loop on \
                regenerate to "improve" a result unless the user asked for variations.
                """
        )
    }

    #if os(macOS)
    /// Writing and checking a Remotion composition.
    static func remotionAuthoring(tool: (String) -> String) -> Skill {
        Skill(
            name: "Remotion compositions",
            description: "Use when the user wants an animated or programmatic clip — titles, motion graphics, 3D scenes, maps, data-driven visuals — or changes to one.",
            instructions: """
                - A composition is a library item whose footage is rendered from \
                `src/Composition.tsx`. \(tool("footage_get")) returns its duration, size, \
                frame rate and current `compositionSource`; \(tool("remotion_list_files")) \
                and \(tool("remotion_read_file")) show the rest of its source tree.
                - Edit with \(tool("remotion_edit_file")) for a targeted change or \
                \(tool("remotion_write_file")) for a rewrite. The COMPOSITION_WIDTH, \
                COMPOSITION_HEIGHT, COMPOSITION_FPS and COMPOSITION_DURATION_IN_FRAMES \
                exports must agree with the item's parameters — change duration or size \
                through \(tool("footage_update")) (durationSeconds, compositionWidth, \
                compositionHeight, compositionFps) and the source is patched to match.
                - Bring assets in with \(tool("remotion_add_image")), \
                \(tool("remotion_add_audio")) or \(tool("remotion_generate_image")) and \
                reference them through `staticFile()` with the `static_path` returned.
                - Look before you report: \(tool("remotion_take_screenshots")) shows the \
                composition across its length, \(tool("remotion_take_screenshot")) one \
                moment. Fix what is wrong, then tell the user.
                - The composition is placed on a timeline as itself and re-renders when \
                a sequence renders; there is no separate render step to call.

                \(RemotionMCPHandlers.authoringInstructions)
                """
        )
    }
    #endif

    /// Transcribing, correcting, translating and exporting captions.
    static func captions(tool: (String) -> String, policy: AgentWritePolicy, offered: Set<String>) -> Skill {
        let policyText: String
        switch policy {
        case .review:
            policyText = """
                - Captions are under review control: \(tool("caption_propose_edits")) is \
                the only way to change one, and it queues your changes for the user to \
                approve. It covers wording, splits and merges, timing (retime) and a \
                single line's translation (set_translation) — so a one-line translation \
                fix goes here, not through \(tool("caption_translate")), which redoes a \
                whole language. Never claim you have changed a caption — say what you \
                have proposed. Everything else you do takes effect immediately.
                """
        case .direct:
            policyText = """
                - Your caption edits take effect immediately: \
                \(tool("caption_update_segment")) rewrites one caption, and \
                \(tool("caption_transcribe")) replaces every caption with a new \
                transcript version. Be careful with anything that replaces existing \
                work, and say what you changed.
                """
        }
        let transcribe = offered.contains("caption_transcribe")
            ? "then \(tool("caption_transcribe")) to fill it (a new transcript version each time; earlier versions stay and \(tool("caption_versions")) switches between them)"
            : "and the user transcribes it from the inspector"
        return Skill(
            name: "Captions",
            description: "Use when the user wants a transcript, subtitle corrections, speaker labels, translations or caption exports.",
            instructions: """
                - A captions item is built from audio: \(tool("caption_create")) with \
                `narration_id` (aligns the narration's own words to its audio) or \
                `audio_path`, \(transcribe).
                - Read before you edit. \(tool("caption_search_segments")) finds captions \
                by their words; \(tool("caption_list_segments")) pages through them. \
                Captions are addressed by their 0-based index.
                \(policyText)
                - \(tool("caption_translate")) translates a whole language and skips \
                captions the user translated by hand. \(tool("caption_set_speakers")) \
                renames or replaces the speaker roster.
                - \(tool("caption_export")) writes VTT, SRT, text or JSON files and \
                returns their paths. On a timeline the item is one clip on T1, and \
                \(tool("sequence_render")) draws it into the picture or writes subtitle \
                tracks and sidecars.
                """
        )
    }
}
