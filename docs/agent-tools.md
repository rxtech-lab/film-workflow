# Agent and MCP tools

The app embeds an MCP server (Settings → MCP) and an agent window (⌘ toolbar
**Agent**) that talk to the same tool surface. The tools speak the editor's
language: a **film** is the open document, the **library** holds **footage
items** in **folders**, every generation is kept as a **take** (version), and
a **sequence** is a timeline of clips cut from those takes. There is no
separate "project" concept — the film is the project.

## Ids

| Argument | What it names | Where it comes from |
|---|---|---|
| `film` | An open document (id, path or name). Optional on every tool; defaults to the active window. `footage_list` accepts `"*"`. | `film_list` |
| `footage_id` | A library item of any kind. Same id the inspector and the agent target use. | `footage_list`, `footage_get`, `footage_create` |
| `sequence_id` | A sequence (also a library item; `footage_get` works on it too). | `sequence_list`, `footage_list` |
| `folder_id` | A library folder. `null` means "no folder". | `folder_list` |
| `source_id` | One take, as `sequence_add_clip` places it: `music:<uuid>`, `narration:<uuid>`, `image:<uuid>`, `video:<uuid>`, `remotion:<uuid>`, `caption:<uuid>`, `imported:<uuid>`. | `sourceId` on `footage_list` rows and takes, and on generator results |
| `clip_id` | A clip on a sequence's timeline. | `sequence_get`, `sequence_add_clip` |

Kinds are the library's own names: `music`, `narration`, `caption`, `image`,
`video`, `remotion`, `sequence`, `imported`.

## Tools

| Family | Tools |
|---|---|
| Film | `film_list` |
| Library | `footage_list`, `footage_get`, `footage_create`, `footage_update`, `footage_duplicate`, `footage_move`, `footage_import`, `footage_delete` |
| Folders | `folder_list`, `folder_create`, `folder_rename`, `folder_delete` |
| Sequences | `sequence_list`, `sequence_create`, `sequence_get`, `sequence_set_timeline`, `sequence_add_clip`, `sequence_remove_clip`, `sequence_render`, `sequence_renders` |
| Generators | `music_generate`, `narration_generate`, `image_generate`, `video_generate`, `video_job_status`, `video_resume` |
| Captions | `caption_create`, `caption_transcribe`, `caption_versions`, `caption_translate`, `caption_list_segments`, `caption_search_segments`, `caption_update_segment`, `caption_propose_edits`, `caption_set_speakers`, `caption_export` |
| Remotion | `remotion_list_files`, `remotion_read_file`, `remotion_write_file`, `remotion_edit_file`, `remotion_take_screenshot`, `remotion_take_screenshots`, `remotion_generate_image`, `remotion_add_image`, `remotion_remove_image`, `remotion_add_audio`, `remotion_remove_audio` |
| Podcast | `podcast_create`, `podcast_list_speakers`, `podcast_add_content`, `podcast_update_content`, `podcast_remove_content`, `podcast_update_settings` (a line-by-line view of a narration item) |

`footage_list` rows carry `id`, `kind`, `name`, `folderId`, `versionCount` and
`sourceId` (the newest take, `null` until something has been generated);
`include_versions: true` adds every take. `footage_get` adds the item's
parameters — the fields `footage_update` accepts, listed in that tool's
description — and its takes. `footage_update` never touches existing takes;
the kind's generator adds a new one.

A typical build: `footage_list` → `footage_create`/`footage_update` →
`<kind>_generate` → `sequence_create` → `sequence_add_clip` (one call per
take) → `sequence_render`.

## The agent window

`AgentPrompts` builds one `AgentContext` for every engine: what a film is,
which film is open, which item is selected (`AgentTarget`), the tool names
as that engine spells them, and a `Skill` for each job — assembling a
sequence, generating footage, Remotion compositions, captions
(`AgentSkills.swift`). A skill is added only when the tools it talks about are
offered.

`AgentToolPolicy` decides what is offered. Every thread sees every tool
except `footage_delete` and `folder_delete`; under the **review** write policy
`caption_update_segment` and `caption_transcribe` are withheld too, so caption
changes go through `caption_propose_edits` and the review sheet. A CLI
engine's own filesystem and shell tools are always disallowed.

## Code map

| Type | Role |
|---|---|
| `MCPToolRegistry` (`clients/mcp/`) | Descriptor list, the `film` argument, dispatch |
| `MCPLibraryHandlers` | `footage_*` and `folder_*`; the one place an id resolves to a model |
| `MCPSequenceHandlers` | `sequence_*` |
| `MCPGenerateHandlers` | The four generators and the video job tools |
| `MCPCaptionHandlers`, `RemotionMCPHandlers`, `MCPPodcastHandlers` | Their families |
| `AgentPrompts`, `AgentSkills` (`clients/agent/`) | The system prompt and its skills |
| `AgentTarget`, `AgentTargetResolver` (`models/`) | What a thread is pointed at, and how the prompt describes it |
