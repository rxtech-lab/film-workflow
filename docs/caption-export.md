# Caption export

Caption projects reach a rendered sequence through the caption clips on its
overlay tracks. The render sheet's **Captions** row decides how those clips
are delivered; it is disabled until a caption clip is on the timeline, and an
audio-only render (`.m4a`) always delivers none.

| Delivery | What happens | Languages | Style |
| --- | --- | --- | --- |
| Burn In | The compositor draws the cues into the picture, exactly as the viewer shows them. | One: the original, one translation, or both (bilingual: original above translation). | `Clip.text`, edited in the sheet's Caption Style disclosure. |
| Embedded Track | The exporter writes a hidden sibling movie; `SubtitleTrackMuxer` copies its tracks untouched and appends one 3GPP timed-text (`tx3g`) track per language, grouped so players list them under Subtitles. | Any set; one track each. The original is tagged with the transcript's language. | Font, size, bold/italic, text and background colour, alignment and vertical position map onto the track's default style. Outline has no tx3g field. |
| Separate File | `CaptionExporter` writes `<movie stem>.<language>.srt` or `.vtt` beside the movie. | Any set; one file each. | None. |
| None | Caption overlays are left out of the picture. | — | — |

Both MP4 and QuickTime containers accept `tx3g`. A language whose translation
is missing from every caption is skipped when writing files rather than
failing the render; the muxer skips tracks with no cues.

## Timing

Every delivery goes through `Clip.timelineInterval` / `Clip.timelineCues` in
`VideoEditorCore`: a cue on the transcript's clock shifts by the clip's start
and in point and is clipped to the clip. Burn-in, tracks and files therefore
agree to the millisecond, and several caption clips on one timeline merge in
time order. Subtitle tracks are continuous — gaps and the tail are empty
samples — because a `tx3g` track with holes keeps the last text on screen.

## Language

`DocumentMediaResolver` takes a `CaptionTextSelection` (`.original`,
`.translation(code)`, `.bilingual(code)`) and resolves caption clips to cues in
that language with `{{term}}` placeholders rendered, the same way the caption
export sheet does. The render service builds one resolver per language for
tracks and files. The live preview and the timeline always show the original.
The render sheet starts on the language the caption editor is showing and
drops any language the film's caption clips lack.

## Style

`TextStyle` (font, size, colours, background opacity, vertical position,
bold, italic, alignment, outline) is stored per clip in `Clip.text` and is the
single source of truth: the clip inspector, the caption project's Style tab
and the render sheet all edit it through `TextStyleEditor`, and `TextRenderer`
draws it for both the preview and the export. The render sheet writes its
changes onto every caption clip in the sequence as they happen, so the viewer
behind the sheet shows the burn-in; each change is one undo step. A caption
project also keeps a default style (`CaptionProject.captionStyle`) that new
clips dropped from it start with; the Style tab can push it onto the clips
already on the timeline.

## Where files land

- **Film version**: the movie is `Renders/Sequences/<id>/vNNN.<ext>` and its
  caption files `vNNN.<language>.<ext>` beside it, recorded in
  `SequenceRender.captionFilePaths`. Deleting the version deletes them;
  exporting a version copies them renamed to the exported stem.
- **Folder**: `<sequence name>.<ext>` (numbered when taken) and
  `<sequence name>.<language>.<ext>`. The render's result lists both.

## MCP

`sequence_render` takes `captions` (`burn_in`, `embedded`, `sidecar`, `none`),
`caption_languages` (BCP-47 codes, `""` for the original; the first entry is
the burn-in language), `caption_bilingual` and `caption_sidecar_format`
(`srt`, `vtt`). Languages must be present on the timeline's caption clips.
Results carry `captions` and `caption_files`.
