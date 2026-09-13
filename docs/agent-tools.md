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
| `film` | An open document (id, path or name). Optional on film tools; defaults to the active window. `footage_list` accepts `"*"`. | `film_list` |
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
| Account | `show_sign_in_dialog` |
| Film | `film_list` |
| Marketplace | `marketplace_list`, `marketplace_get`, `show_marketplace_item`, `marketplace_install` |
| Marketplace authoring (admin) | `marketplace_create`, `marketplace_update`, `marketplace_upload`, `marketplace_generate`, `marketplace_render_preview`, `marketplace_job_status`, `marketplace_retry`, `marketplace_publish`, `marketplace_workspace` |
| Templates | `project_template_from_film` (admin), `project_template_apply` |
| Library | `footage_list`, `footage_get`, `footage_create`, `footage_update`, `footage_duplicate`, `footage_move`, `footage_import`, `footage_delete` |
| Folders | `folder_list`, `folder_create`, `folder_rename`, `folder_delete` |
| Sequences | `sequence_list`, `sequence_create`, `sequence_get`, `sequence_set_timeline`, `sequence_add_clip`, `sequence_remove_clip`, `sequence_render`, `sequence_renders` |
| Generators | `music_generate`, `narration_generate`, `image_generate`, `video_generate`, `video_job_status`, `video_resume` |
| Captions | `caption_create`, `caption_transcribe`, `caption_versions`, `caption_translate`, `caption_list_segments`, `caption_search_segments`, `caption_update_segment`, `caption_propose_edits`, `caption_set_speakers`, `caption_export` |
| Remotion | `remotion_list_files`, `remotion_read_file`, `remotion_write_file`, `remotion_edit_file`, `remotion_take_screenshot`, `remotion_take_screenshots`, `remotion_generate_image`, `remotion_add_image`, `remotion_remove_image`, `remotion_add_audio`, `remotion_remove_audio` |
| Podcast | `podcast_create`, `podcast_list_speakers`, `podcast_add_content`, `podcast_update_content`, `podcast_remove_content`, `podcast_update_settings` (a line-by-line view of a narration item) |

`show_sign_in_dialog` takes no arguments and works without an open film. It
requests the native RxLab sign-in sheet when the user is signed out, returning
`status: "sign_in_requested"` and `isAuthenticated: false`. The user completes
sign-in in the sheet; the agent waits for their confirmation before retrying
an operation that requires an account. If already signed in, it returns
`status: "already_signed_in"` and `isAuthenticated: true` without opening a sheet.

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

Conversation history saves the SDK's message and block order in a versioned
snapshot at tool/block boundaries and turn completion. Text, thinking and tool
calls reload in that order; tool blocks reference their existing result rows
instead of appending another copy. Message IDs remain stable for compaction.
Older histories without a snapshot retain their saved content and timestamp
order; their original text/tool interleaving was not recorded.


## Marketplace workflow

Browse without an open film; set `marketplace_list.drafts=true` as an admin to
list manageable items. Only `show_marketplace_item` displays a native card.
Reads, creates, updates, uploads, installs, publishing and template application
remain normal tool results, even when they contain marketplace item data.
Finish the requested authoring/revision work and preview jobs, then call
`show_marketplace_item` once per item; do not show cards for intermediate saves
or polling. A new user request or meaningful completed revision can show the
item again. The renderer checks the tool name for both live and saved transcripts.
Create uses camelCase listing
fields in `item`, optional structured `content`, and a reusable UUID `draftId`.
Create never publishes. Publish requires an explicit user request or the
card/editor Publish button. Admin tool handlers recheck backend access even
when invoked directly over MCP.

Set `show_marketplace_item.show_publish_button=false` to hide Edit and
Publish/Unpublish on that card. The parameter defaults to `true`; purchase,
install and template-use actions remain available. The choice is saved with
the card and preserved when reopening the conversation.

Use `marketplace_generate` for supported content or covers, and
`marketplace_render_preview` for a short rendered demonstration. These return
persisted jobs; poll status, retry existing jobs/files after failure, and show
the updated card on completion. For Remotion, use the separate film ID returned
by `marketplace_workspace` with the existing composition and sequence tools.

Extraction requires a film and selected/explicit sequence. The portable
result needs the agent's generalized prompt and directions before publication.
`marketplace_bindings` maps known source IDs, or `modifier:<definitionId>`, to
explicit marketplace item IDs when provenance is missing. Template previews
use mock images, never copied source footage.

Application requires an existing film and an entitled template. Inspect
footage first, propose bindings, and show the needed shots and dependency
prices. Use the returned `application.id` in subsequent `application_id` calls;
`footage_bindings` maps requirement IDs to source IDs. Missing paid items need
the user's purchase through the card. Build, adapt and render only the new
sequence identified by `application.sequenceId`. When a Remotion dependency
needs preparation, author its composition from the imported prompt, render the
new sequence, then resume the same application.
