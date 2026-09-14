# Simple mode

A guided path from **New Film** to a first cut. The user answers a short brief,
picks a marketplace project template the agent found, chooses how it should
look, and watches the film build. Refinement is available in the preview and the full editor.

The advanced flow is unchanged: **Blank film** in the gallery, or
**File › New Blank Film…** (⌘⇧N), still opens a save panel and an empty
timeline.

## The flow

| Phase | What the user sees | What the agent does |
|---|---|---|
| Engine | Available AI engines and setup status | — |
| Brief | A form: film name, website, description, file picker | — |
| Location | Native save picker, selected path, **Create Film** | — |
| Research | A spinner with a status line | `web_read` the site, `marketplace_list` project templates, then `wizard_present_templates` — or `wizard_skip_templates` when none fit |
| Template | Ranked template cards, or the no-template page | waits |
| Style | A page the agent authored | `marketplace_get`, `footage_list`, then `wizard_present_options` |
| Build | The preview, filling up | `project_template_apply`, then the sequence tools |
| Preview | Player with scrubber, clip strip, refine field, **Edit in Editor** (disabled while generating) | waits, or refines |

The info button beside the preview status opens the agent's live messages and
tool activity. It uses the regular agent transcript renderer and remains
available after generation finishes.

After the brief, the user chooses a filename and location with the native save
picker, then confirms **Create Film**. Cancelling the picker preserves the brief
and any previous selection. Existing packages are never overwritten; a collision
stays on the location step so the user can choose another name. Uploads are copied into the package
with `MediaImporter.importCopy` before the agent's first turn, so it can place
them by `sourceId` without importing anything itself.

## Where the code lives

| Concern | File |
|---|---|
| Catalog, steps, intake schema, prompts | `Packages/RxFilmTemplates/Sources/FilmTemplateKit` |
| json-render spec, state, SwiftUI renderer | `Packages/RxFilmTemplates/Sources/JSONRenderUI` |
| Gallery, shell, form, pages | `Packages/RxFilmTemplates/Sources/FilmTemplateUI` |
| Session state machine | `film-workflow/clients/simplemode/SimpleModeSession.swift` |
| Document, imports, turns, status | `film-workflow/clients/simplemode/SimpleModeCoordinator.swift` |
| Wizard host and preview | `film-workflow/views/simplemode/` |
| Wizard and web tools | `film-workflow/clients/mcp/handlers/MCPWizardHandlers.swift`, `MCPWebHandlers.swift` |
| Playhead follow-along | `film-workflow/document/TimelineFocus.swift` |

The package holds no app types. Its pages take data and callbacks, and the
preview page takes the player as an injected view, so `swift test` runs the
whole package without an Xcode project.

## Adding a template

Add a `FilmTemplate` to `FilmTemplateCatalog.all` with its own
`IntakeFormDefinition` and `WizardPromptSet`. Nothing else changes: the gallery
groups by `FilmTemplateGroup`, and the session's phases are the same for every
template. A new group only needs a case on `FilmTemplateGroup`.

## The wizard protocol

The wizard shows pages, not a transcript, so the agent cannot ask a question by
writing one. Each phase ends by calling exactly one tool and stopping; the
user's answer arrives as the next turn, written into the transcript as a system
line by `AgentController.recordDecision`.

- `wizard_present_templates { candidates: [{ item_id, reason, fit_score? }], summary? }`
- `wizard_skip_templates { reason }`
- `wizard_present_options { spec, initial_state?, title? }`
- `wizard_report_progress { message }`
- `web_read { url, max_chars? }` — the only route to the open web; public
  http(s) only, with loopback, private and link-local addresses refused on
  every hop, redirects included.

A tool that arrives in the wrong phase is refused with a message naming the
phase, rather than silently replacing the page the user is reading. Wizard tools
are withheld from ordinary conversations, and a Simple mode thread sees a
narrower allowlist than a conversation (`AgentToolPolicy.simpleModeTools`) —
enforced both by `agent.allowedTools` and by the CLI approval hook, which reads
the thread's mode.

## The json-render subset

Option pages use the [json-render](https://json-render.dev) flat format: a
`root` element id and an `elements` map of `{ type, props, children }`. There is
no Swift renderer upstream, so `JSONRenderUI` implements a closed catalog:
`Stack`, `Grid`, `Card`, `Heading`, `Text`, `Caption`, `Image`, `Divider`,
`Spacer`, `OptionGroup`, `Toggle`, `Chips`, `TextField`.

Props may be literals or `{"$state": "/path"}`; inputs bind with
`{"$bindState": "/path"}`; `{"$template": "Hi ${/name}"}` interpolates; and a
`visible` array gates an element on `$state` truthiness, `eq` or `not`.

Decoding is deliberately lenient — an unknown element type draws a placeholder
and a dangling child id is reported back — because one unfamiliar element should
cost that card, not the page. Only a missing `root` or `elements` fails, and
after two unusable specs the wizard offers to build on the agent's own
recommendation instead of stranding the user.

`imageUrl` on an option accepts a `sourceId` as well as a URL, so a card can
show the user's own upload; `SimpleModeThumbnails` resolves it.

## When there is no template

The catalog can hold no project template that fits, or none at all. Presenting
an empty list is refused and an options page does not belong in research, so
that combination used to leave the agent with no legal move and the user on a
spinner that never resolved. `wizard_skip_templates` is the way out: the wizard
shows what the agent searched for and offers **Build Without a Template**, and
the run continues on `planOptionsWithoutTemplate` and `buildWithoutTemplate` —
the agent designs the shot plan itself and cuts the sequence with the
`sequence_*` tools instead of `project_template_apply`. It is the same shape as
the options fallback: the user is told what happened and decides.

## Watching it build

The wizard uses Liquid Glass navigation and controls, with a compact header and
build notes in a separate popover. Its preview uses the editor's live Remotion
surfaces, or rendered sources when effects require the compositor. Source edits
reload the preview; play, pause, frame stepping, and seeking share one transport.
The decoded timeline cache is checked against its stored data so agent updates
cannot leave the player showing an older, empty cut.

`TimelineFocus` is how the playhead follows the agent. A handler that changed a
clip sets `ProjectDocument.pendingTimelineFocus`, and whichever views are
showing that film move to it: the wizard preview during the first build, the
editor window during a refine from the Agent window. Producers are the
`sequence_*` handlers and `ProjectTemplateService.advance`; consumers wait for
the player to finish loading first, because the reload and the focus arrive from
two observers of the same edit in no fixed order.
