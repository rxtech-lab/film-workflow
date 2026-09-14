# Marketplace

The **Marketplace** window (toolbar button, or ⌘⌥M) lists items an admin has
published through the app, agent, or website: project templates, footage,
Remotion prompts, music, sound effects, fonts, transitions and effects. Each item has a category, a preview image and
optionally a preview video, and a price in credits (0 = free).

## In the app

- The **What's New** sheet introduces Marketplace and the RxFilm subscription
  service once per feature card. Reopen it from **RxFilmStudio → What's New…**;
  **Explore Marketplace** closes the sheet and opens the catalog.
- Browse by kind in the navigation sidebar; the kinds, their icons and the selected kind's categories all come from the backend, with item counts. The sidebar can be resized or hidden, and search filters the grid. Click a card to open its detail sheet; hovering a card with a video preview plays it in place, muted.
- Signed-out users can browse. Buying and installing need an RxLab account.
- **Buy** charges the price through rx-subscription in one hold-and-settle; a
  retried purchase re-attaches to the same hold and row, so nothing is charged
  twice. A refused purchase raises the usual "Not enough credits" alert.
- **Install** fetches a short-lived download URL and streams the content file
  to `~/Library/Application Support/com.rxlab.film-workflow/Marketplace/<kind>/<itemId>/`
  beside a `manifest.json` and a cached preview still. Installed items are
  shared by every film. Uninstall and Reveal in Finder live under the
  **Installed** menu.
- **Add to Film** (footage, music, sound effects, Remotion prompts) copies the
  file into the key film: media becomes an imported asset; a prompt becomes a
  Remotion composition with that prompt filled in.
- The same items also appear in every film's **Library** panel: a
  Library / Marketplace switch in the panel's title bar flips between the
  film's own footage and what is installed, sectioned by kind with preview
  stills and lengths. Installed items are sources shared by every film rather than
  footage of this one, so they don't drag onto the timeline directly:
  double-click a card (or **Add to Film** / **Add to Folder** in its context
  menu) to copy it into the film, which switches back to the Library tab with
  the copy selected and ready to drag. `LibraryMarketplaceGrid` renders the
  tab from `MarketplaceStore.libraryItems`.
- Fonts are registered in the process at launch and after install
  (`MarketplaceFonts`), so they appear in the caption Text Style picker.
- Effects and transitions are JSON descriptors over a built-in Core Image
  filter (`CIFilterModifierDescriptor` in `RxVideoEffects`). `InstalledModifierLoader`
  validates each one against the filters this system has and merges them into
  `ModifierCatalog.current`, so they show up in the Effects & Transitions
  browser with their own preview still.

## Code map

| Type | Role |
|---|---|
| `MarketplaceClient` (`clients/marketplace/`) | `api/v1/marketplace/*` over `BackendClient`; anonymous fallback for the catalog |
| `MarketplaceStore` | Catalog page, purchases, installs with progress, the installed manifests |
| `MarketplaceDownloader` | Download task with progress, straight to disk |
| `MarketplaceInstaller` | "Add to Film" per kind, through `MediaImporter` |
| `InstalledModifierLoader`, `MarketplaceFonts` | Post-install registration for effects/transitions and fonts |
| `MarketplaceWindowView` (`views/marketplace/`) | `NavigationSplitView` category sidebar, grid with hover-autoplay cards, detail sheet with `VideoPlayer` preview; `#Preview`s run on a canned transport |

## On the website

`/admin/marketplace` (users whose IdP roles include `admin`) creates items,
uploads previews and content straight to R2 through presigned PUTs, edits
effect/transition descriptors in place, and publishes. The item form changes
with the kind: footage, music, sound effects, fonts and prompts get a content
file slot with kind-specific accepted types; effects and transitions get the
descriptor editor instead; templates get a shot/requirements editor, and preview
video uploads are available for every kind. On
a new item the files are staged and uploaded right after the draft is created.

Categories are rows in `marketplace_categories`, scoped to a kind and created
inline from the item form ("New" next to the category picker). Items reference
them by `category_id`; the wire keeps `category` as the slug (what the app
filters on) and adds `category_name` for display. Data lives in Neon Postgres
(`marketplace_kinds`, `marketplace_categories`, `marketplace_items`, `marketplace_purchases`). The app talks to
`GET api/v1/marketplace/items`, `GET …/items/[id]`, `POST …/items/[id]/purchase`,
`GET …/items/[id]/download`, `GET api/v1/marketplace/taxonomy` and `GET api/v1/marketplace/purchases`.

### The sidebar comes from the backend

Both levels of the app's sidebar are server data. `marketplace_kinds` holds one
row per kind with the label, an SF Symbol name and a sort order;
`marketplace_categories.icon` holds a symbol per category.
`GET api/v1/marketplace/taxonomy` returns both, with published-item counts, and
the app draws exactly what it gets — so a rename or a new icon needs no release.
`/admin/marketplace/taxonomy` ("Sidebar" on the admin marketplace page) edits
them, one row at a time.

Two things keep this safe on the app side: a symbol the running macOS cannot
draw falls back to the one the app ships with (`MarketplaceKind.systemImage`,
`folder` for categories), and a kind the build does not know about is dropped
from the payload instead of failing the whole decode. A taxonomy request that
fails leaves the built-in sidebar up rather than emptying it. The app fetches it
once per launch; the window's Refresh button forces a re-fetch.


## Admin authoring in the app and agent

Admins get two sidebar destinations backed by the same list view: **My
Marketplace** (their own drafts and published items) and **Manage Items**
(everything this account may manage). Both offer status filters, search and
pagination. The server filters by the authenticated author's `createdBy` before
counting and paginating (`GET /api/v1/admin/marketplace/items?scope=mine`).
Edit, Publish/Unpublish and Delete live in each row's context menu, so a
destructive action is never one stray click away and the editor itself carries
no publishing controls; clicking a row opens the editor. Publishing uses the
existing content and preview validation; changes refresh the author's list and
catalog. **Create Item** remains in the toolbar. The editor supports
free-by-default credit pricing, categories, tags, content files or film assets,
generated covers/content, excerpt selection and preview jobs, with the listing
preview as a hero above the fields, per-section help as footers, and one status
bar carrying progress, errors, Done and Save Draft. Effects and transitions have
native preset controls and an advanced descriptor editor. Catalog and draft
operations also work with no film open. Roles from `/api/v1/me` are decoded; the
admin capabilities endpoint and every authoring operation independently enforce
the administrator role.

A sequence's context menu in the library offers **Create Marketplace Template…**
for admins: it opens the agent on `project_template_from_film` for that
sequence, which extracts it into a draft, generalizes it and prepares a mock
preview. The item never publishes itself from there.

Both editors are drawn from one description of the form. `lib/marketplace/form-schema.ts`
names the fields, what they accept, which kinds they belong to, and what each
kind needs for its content and previews; the website imports it and the app
fetches it from `GET /api/v1/admin/marketplace/form-schema`, so a field added
there appears in both without an app release. A field id is the path into the
item input it edits (`title`, `pricePoints`, `metadata.tags`). The app decides
only which control draws a field, drawing the form once the schema and the item
have loaded, and drops a field type or kind this build does not know rather
than failing the payload. Deleting an item is available in both, asks twice in
the app (from the row's context menu), and the server still refuses once the
item has been bought.

`MarketplaceAuthoringService` is shared by the native editor and MCP handlers.
The website server actions and `/api/v1/admin/marketplace/*` share
`lib/marketplace/authoring.ts`. The REST surface includes capabilities, the
form schema, categories, paginated item listing, item create/update, structured
content, upload authorization/finalization, asset removal, item deletion, and
publish/unpublish.
Uploaded objects must belong to the item, account and slot; finalization
checks storage size, MIME type, file signature and structured content. Preview
metadata is separate from the content's duration and dimensions.

Draft jobs and their media live in an account-scoped `MarketplaceAuthoring`
directory. Each item has a separate `Preview.rxfilmstudio` workspace. Finished
media are saved before upload, and retry retains the same draft, excerpt,
operation and generated files. Video generation resumes a persisted provider
operation when one exists. The normal image, video and music services retain
their existing configuration, account and credit requirements.

Previews use the normal timeline exporter at H.264 MP4 / 720p, preserving the
aspect ratio, and are capped at 15 seconds. Footage previews excerpt the real
clip; music/sound previews combine cover art with actual audible audio; font
previews render a specimen with the supplied font; modifiers demonstrate the
supplied descriptor on mock images. A Remotion demonstration is authored by
the agent from the actual prompt and mock assets in the authoring workspace,
then rendered and supplied to `marketplace_render_preview`. Template images
are always generated mock scenes. Original film media never enters the
template preview resolver. Explicit playback supports sound; hover is muted.

## Portable project templates

`ProjectTemplateDefinition` version 1 contains the prompt, video style,
dimensions/frame rate, editing guidance, ordered shots with stable IDs,
footage requirements and marketplace references. A shot can reference a
footage requirement or a marketplace source, plus effect/transition settings.
The published JSON contains neither a serialized timeline nor source-film
IDs, paths, bookmarks or original media. Public summaries include requirements,
dependencies and a prompt excerpt; paid full content uses the existing
entitlement-gated download endpoint.

`project_template_from_film` selects the active sequence, the sole sequence,
or an explicit sequence ID. Ambiguity requires a choice. Extraction captures
shot prompts, framing/playback guidance, durations, modifiers and known asset
provenance. The agent then generalizes project-specific language and edits the
draft. Imported assets and Remotion prompts retain marketplace identity;
installed modifiers are resolved through manifests. Unidentified sources can
be explicitly mapped using `marketplace_bindings`, never guessed by name.

Templates require a cover and mock preview to publish. Publication also
checks completeness, available dependencies and modifier/source references.
Changing template content returns it to draft and requires a fresh mock
preview; saving identical structured content preserves the existing preview.

**Use in Current Film** opens a film-bound agent conversation. The agent
inspects footage, proposes matches, asks for missing shots, offers generation,
and shows separate dependency prices. Missing paid items are purchased with
the card's Buy button before use. Unavailable required dependencies block
application with an explanation. Remotion dependencies are imported with their
prompt and prepared by the agent before final rendering.

`TemplateApplications/<application-id>.json` in the film stores the template
snapshot, footage/dependency bindings, outstanding requirements and new
sequence ID. Resume with that ID and updated bindings. Repeated initial calls
reuse the film's existing application for the item; an explicit new UUID
requests another application. Original sequences are preserved. Once ready,
follow-up calls without changed bindings retain subsequent edits to the new
sequence. The agent adapts and renders only that sequence.

Marketplace tool results persist complete structured payloads, including item
identity and template snapshots. Native cards remain separate from collapsed
tool groups and accept both native and namespaced CLI tool-result envelopes.

## Rollout order

1. Apply additive migration `drizzle/0004_misty_genesis.sql` (generated enum
   addition only) using the existing database migration process.
2. Deploy the backward-compatible website/backend before distributing the
   updated macOS app. Default catalog/category/purchase-list responses exclude
   templates; new clients opt in with `catalog_version=2`.
3. Distribute the app, then author and publish templates through an admin
   account. Items start as drafts and free; publishing remains explicit.

No production deployment is performed by this implementation. Startup
selection, bundled dependency purchases, dedicated sound/font generators and
new provider integrations remain deferred. Test execution was paused at the
user's request during implementation; newly added coverage is retained for a
later validation run.
