# MCP Server

Film Workflow can expose the open film — its library, generators and sequences — over an HTTP **MCP** endpoint, so your own
tools — an editor, a command-line agent, a script — can drive the app directly.

This is also how the **Claude Code** and **Codex** agent engines talk back to the app.

Everything below lives in **Settings › MCP Server**.

## Turn it on

**Enable MCP server** starts the server. Once enabled it auto-starts whenever the app launches.

## Network

- **Bind** — **Localhost only (127.0.0.1)** or **All interfaces (0.0.0.0)**. Localhost is the
  default and the safer choice: only software on this machine can connect.
- **Base port** — 7711 by default. If that port is in use, the next free port up to base+9 is used
  instead. The **Status** section always shows the port actually in use, and says when it differs
  from the base port.

## Status

A coloured dot and a status line report whether the server is running, and the full URL is shown
with a copy button next to it. Errors appear here in red rather than failing silently.

## Bearer token

A token is generated for you the first time you enable the server.

- **Show** / **Hide** reveals the token, which is otherwise masked.
- The copy button puts it on the clipboard.
- **Regenerate token** issues a new one. Anything already connected with the old token will stop
  working.

The token is **required when bound to all interfaces**. Localhost requests skip the check. Send it
as a header on every request:

```
Authorization: Bearer <token>
```

The token is stored in the system Keychain, not in a settings file.

## Connect from Claude Code

When the server is running, the settings pane shows a ready-made command with your actual URL and
token filled in. Copy it and run it:

```
claude mcp add --transport http film http://127.0.0.1:7711/...
```

Bound to all interfaces, the same command includes the `Authorization` header.

## What the tools cover

The server exposes the app's own operations, in the editor's own words: a **film** is the open
document, the **library** holds **footage items** in **folders**, every generation is kept as a
**take**, and a **sequence** is a timeline cut from those takes. Every tool accepts an optional `film`
argument (an id, path or name from `film_list`) and otherwise acts on the active window.

**Film**

`film_list`

**Library and folders**

`footage_list`, `footage_get`, `footage_create`, `footage_update`, `footage_duplicate`,
`footage_move`, `footage_import`, `footage_delete`, `folder_list`, `folder_create`,
`folder_rename`, `folder_delete`

Items are addressed by `footage_id`; kinds are `music`, `narration`, `caption`, `image`, `video`,
`remotion`, `sequence` and `imported`. `footage_list` rows carry a `sourceId` — the newest take —
that `sequence_add_clip` places on a track.

**Generation**

`music_generate`, `narration_generate`, `image_generate`, `video_generate`, `video_job_status`,
`video_resume`

**Captions**

`caption_create`, `caption_transcribe`, `caption_list_segments`, `caption_search_segments`,
`caption_update_segment`, `caption_set_speakers`, `caption_propose_edits`, `caption_translate`,
`caption_versions`, `caption_export`

**Podcast**

`podcast_create`, `podcast_add_content`, `podcast_update_content`, `podcast_remove_content`,
`podcast_list_speakers`, `podcast_update_settings`

**Remotion**

`remotion_list_files`, `remotion_read_file`, `remotion_write_file`, `remotion_edit_file`,
`remotion_add_image`, `remotion_remove_image`, `remotion_add_audio`, `remotion_remove_audio`,
`remotion_generate_image`, `remotion_take_screenshot`, `remotion_take_screenshots`

**Sequences**

`sequence_create`, `sequence_list`, `sequence_get`, `sequence_set_timeline`, `sequence_add_clip`,
`sequence_remove_clip`, `sequence_render`, `sequence_renders`

`sequence_render` delivers the caption clips on the timeline the way `captions` asks: `burn_in`
(drawn into the picture), `embedded` (one subtitle track per language inside the movie), `sidecar`
(one `.srt` or `.vtt` per language beside the movie, per `caption_sidecar_format`) or `none`.
`caption_languages` lists BCP-47 codes, with `""` for the original; for burn-in the first entry is
the language drawn and `caption_bilingual` adds the original above it. Results report `captions` and
`caption_files`.

## Notes

- Translations requested over MCP always use the AI backend. Apple's on-device translation engine
  only runs inside the app.
- The caption **write policy** in **Settings › Agent** applies to the app's own agent threads. An
  outside client connecting over MCP is a separate consumer of these tools.
- Binding to all interfaces exposes the server to your local network. Do it only on a network you
  trust, and keep the bearer token secret.
