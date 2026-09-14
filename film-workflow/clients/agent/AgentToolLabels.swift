import Foundation

/// Plain-language names for what a tool is doing.
///
/// The wizard shows one line of status instead of a transcript, so a raw tool
/// name would be the only thing a user sees during a long build. Anything not
/// listed falls back to a readable form of its own name.
nonisolated enum AgentToolLabels {
    static func progressLabel(for tool: String) -> String {
        if let known = labels[tool] { return known }
        // `sequence_add_clip` reads better as "Sequence add clip…" than as
        // nothing at all.
        let words = tool.split(separator: "_").joined(separator: " ")
        guard let first = words.first else { return "Working…" }
        return first.uppercased() + words.dropFirst() + "…"
    }

    private static let labels: [String: String] = [
        "web_read": "Reading the website…",
        "marketplace_list": "Searching the marketplace…",
        "marketplace_get": "Reading a template…",
        "marketplace_show": "Reading a template…",
        "marketplace_install": "Installing an asset…",
        "project_template_apply": "Applying the template…",
        "footage_list": "Looking at your footage…",
        "footage_get": "Looking at your footage…",
        "footage_import": "Importing footage…",
        "footage_create": "Adding to the library…",
        "footage_update": "Updating footage…",
        "image_generate": "Generating an image…",
        "video_generate": "Generating video…",
        "music_generate": "Composing music…",
        "narration_generate": "Recording narration…",
        "sequence_create": "Creating the sequence…",
        "sequence_get": "Reading the timeline…",
        "sequence_list": "Reading the timeline…",
        "sequence_add_track": "Adding a track…",
        "sequence_reorder_tracks": "Reordering tracks…",
        "sequence_add_clip": "Placing a clip…",
        "sequence_remove_clip": "Removing a clip…",
        "sequence_set_timeline": "Arranging the timeline…",
        "caption_create": "Adding captions…",
        "caption_transcribe": "Transcribing…",
        "wizard_present_templates": "Preparing template options…",
        "wizard_present_options": "Preparing your choices…",
        "wizard_report_progress": "Working…",
    ]
}
