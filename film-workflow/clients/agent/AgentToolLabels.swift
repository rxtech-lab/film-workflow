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
        "web_read": String(localized: "Reading the website…"),
        "marketplace_list": String(localized: "Searching the marketplace…"),
        "marketplace_get": String(localized: "Reading a template…"),
        "show_marketplace_item": String(localized: "Showing a marketplace item…"),
        "marketplace_install": String(localized: "Installing an asset…"),
        "marketplace_add_to_film": String(localized: "Adding an asset to the film…"),
        "project_template_apply": String(localized: "Applying the template…"),
        "models_list": String(localized: "Checking available models…"),
        "footage_list": String(localized: "Looking at your footage…"),
        "footage_get": String(localized: "Looking at your footage…"),
        "footage_import": String(localized: "Importing footage…"),
        "footage_create": String(localized: "Adding to the library…"),
        "footage_update": String(localized: "Updating footage…"),
        "image_generate": String(localized: "Generating an image…"),
        "video_generate": String(localized: "Generating video…"),
        "music_generate": String(localized: "Composing music…"),
        "narration_generate": String(localized: "Recording narration…"),
        "sequence_create": String(localized: "Creating the sequence…"),
        "sequence_get": String(localized: "Reading the timeline…"),
        "sequence_list": String(localized: "Reading the timeline…"),
        "sequence_add_track": String(localized: "Adding a track…"),
        "sequence_reorder_tracks": String(localized: "Reordering tracks…"),
        "sequence_add_clip": String(localized: "Placing a clip…"),
        "sequence_remove_clip": String(localized: "Removing a clip…"),
        "sequence_set_timeline": String(localized: "Arranging the timeline…"),
        "remotion_write_file": String(localized: "Writing a card…"),
        "remotion_edit_file": String(localized: "Editing a card…"),
        "remotion_generate_image": String(localized: "Generating an image…"),
        "remotion_take_screenshot": String(localized: "Checking how it looks…"),
        "remotion_take_screenshots": String(localized: "Checking how it looks…"),
        "caption_create": String(localized: "Adding captions…"),
        "caption_transcribe": String(localized: "Transcribing…"),
        "wizard_present_templates": String(localized: "Preparing template options…"),
        "wizard_skip_templates": String(localized: "Looking for another way in…"),
        "wizard_present_options": String(localized: "Preparing your choices…"),
        "wizard_report_progress": String(localized: "Working…"),
    ]
}
