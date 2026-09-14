# Caption export

Caption projects reach a rendered sequence through the caption clips on its
caption and overlay tracks — a sequence may carry several caption lanes, and
every one of them is collected. The render sheet's **Captions** row decides how those clips
are delivered; it is disabled until a caption clip is on the timeline, and an
audio-only render (`.m4a`) always delivers none.

| Delivery | What happens | Languages | Style |
| --- | --- | --- | --- |
| Burn In | The compositor draws the cues into the picture, exactly as the viewer shows them. | Whatever each caption clip names in `Clip.captions`: the original, a translation, or several stacked on one caption. | `Clip.text`, edited in the sheet's Caption Style disclosure. |
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

`DocumentMediaResolver` resolves a caption clip to cues with `{{term}}`
placeholders rendered, and hangs **every** translation on each `TextCue`
(`TextCue.translations`, keyed by BCP-47, with the transcript itself under
`""`). Its `CaptionTextSelection` still decides a cue's own `text`, which is
what subtitle tracks and sidecar files carry — the render service builds one
resolver per language for those.

What a burned-in caption *draws* is a per-clip choice instead:
`Clip.captions` (`CaptionOptions`) names the languages drawn on one caption,
top line first, and whether punctuation is dropped. A language the project has
not translated falls back to the transcript, and a line identical to the one
above it is dropped, so asking for original + a missing translation reads as
one line. `CaptionPunctuation.strip` is the package's copy of the caption
exporter's rule, pinned to it by a test, so a burned-in caption and a sidecar
file written with the same option read alike.

Three places edit that one choice, and the viewer always shows the result:

- the **clip inspector**'s Captions section — a row per available language
  plus Strip Punctuation, so two caption clips in one sequence can speak
  different languages;
- the **render sheet**'s Language and Bilingual rows, which write onto every
  caption clip as they change, the same way the caption style does, and start
  from what the clips already agree on (falling back to the language the
  caption editor is showing);
- a **render request that names a burn-in language** — an agent's
  `sequence_render`, say — which overrides the clips for that export only,
  keeping each clip's punctuation choice.

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
