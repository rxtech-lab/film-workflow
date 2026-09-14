# Marketplace

The **Marketplace** window (toolbar button, or ⌘⌥M) lists items an admin has
published through the app, agent, or website: project templates, footage,
Remotion compositions, music, sound effects, fonts, transitions and effects. Each item has a category, a preview image and
optionally a preview video, and a price in credits (0 = free).

Music and sound-effect detail sheets include audio playback, seeking and pause.
They play the public preview when available, otherwise installed audio or an
entitled download. The audio preview upload slot accepts MP3, WAV, M4A and AAC
as well as video; unpurchased paid content still requires a public preview.

Music uploads can include optional SRT or VTT lyric captions and translated
tracks, one per language code (for example `en` and `zh-Hans`). Both authoring
forms save these in `metadata.lyricTracks`, and preview listeners can select a
language or turn captions off. Caption times refer to the full song. For an
excerpt, set its start time before uploading; generated previews record that
offset automatically. Limits are 12 languages, 2,000 cues per track, and 500 KB
of caption data. These metadata additions require no database migration.

In a film, right-click a music take or imported audio and choose **Add Lyrics
Timing…**, **Edit Lyrics & Timing…**, or **Merge Captions as Lyrics**. Caption
context menus also offer **Merge as Lyrics into Music**. These actions are
available from the library, footage preview and timeline. Merging copies the
active caption version, including word timings and translations; the source
captions and earlier lyric versions remain available. Lyrics belong to the
selected recording and also appear in the caption library.

New lyric text starts with estimated timings and opens the caption retimer.
Use the caption view to edit text, retime while listening, and translate lyrics.
Music previews follow the saved timings and offer a language picker and Off.
Creating a Marketplace item from that audio includes its current lyrics and
translations in the draft.

Footage covers both stills and clips. Which one an item is comes from its
content file at upload (`metadata.mediaType`), never from the author, so the
shelf always matches the bytes: the sidebar nests **Footage → Images / Video**,
with the ordinary categories grouping underneath either. A clip's card prints a
resolution bucket (`4K`, `1440p`, `1080p`, `720p`, `SD`) measured on the short
side, so a portrait clip reads the same as the landscape one it was cropped
from; the detail sheet keeps the exact dimensions. Cards also show an item's
first tags.

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
- **Add to Film** (footage, music, sound effects, Remotion compositions) copies
  the file into the key film: media becomes an imported asset — a still as an
  image, a clip as video; a Remotion archive is unpacked into a composition of
  that film's own, with its prompt and canvas settings filled in.
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
| `MarketplaceInstaller` | "Add to Film" per kind, through `MediaImporter`; unpacks a Remotion archive into the film |
| `RemotionProjectArchive` (`clients/marketplace/`) | The composition zip: builds one from a project, and validates/extracts one before it reaches a film |
| `MarketplaceMediaType`, `MarketplaceResolution` | Footage's still/clip split, and the card's resolution bucket |
| `BackendConfig.acceptLanguage` (`config/`) | The `Accept-Language` every backend request carries, from the bundle's own languages |
| `MarketplaceSeedHost` (`views/marketplace/`) | "Create Marketplace Item…" for all six editor surfaces: gating, seed preparation, errors, the editor sheet |
| `InstalledModifierLoader`, `MarketplaceFonts` | Post-install registration for effects/transitions and fonts |
| `MarketplaceWindowView` (`views/marketplace/`) | `NavigationSplitView` category sidebar, grid with hover-autoplay cards, detail sheet with `VideoPlayer` preview; `#Preview`s run on a canned transport |

## On the website

`/admin/marketplace` (users whose IdP roles include `admin`) creates items,
uploads previews and content straight to R2 through presigned PUTs, edits
effect/transition descriptors in place, and publishes. The item form changes
with the kind: footage, music, sound effects, fonts and Remotion compositions
get a content file slot with kind-specific accepted types; effects and
transitions get the descriptor editor instead; templates get a shot/requirements
editor, and preview video uploads are available for every kind. On a new item
the files are staged and uploaded right after the draft is created. The browser
reads what it can off a chosen file — dimensions and duration for a clip,
dimensions for a still, nothing from an archive, whose facts the app supplies
with the upload instead.

Categories are rows in `marketplace_categories`, scoped to a kind and created
inline from the item form ("New Category" next to the category picker), which
also renames the selected one and changes its symbol ("Edit Category"). The
slug is not patchable, so items already filed under a renamed category keep
filtering the same. The icon is picked, never typed: the app reads the running
system's symbol index (`/System/Library/CoreServices/CoreGlyphs.bundle`) and
offers every SF Symbol it lists — roughly 6,500 once localized variants and
Apple's trademark-restricted symbols are dropped — searchable by name and by
Apple's own search keywords. Items reference
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


### The language is the request's

Every request the app makes to our backend carries `Accept-Language`, built
from `Bundle.main.preferredLocalizations` — the languages the app is actually
drawn in, so the text around a title matches the title
(`BackendConfig.acceptLanguage`, sent by `BackendClient` and by
`MarketplaceClient`'s anonymous fallback). The backend negotiates it down to
one of the locales it serves — today `en` and `zh-Hans`, matching
`Localizable.xcstrings` — and answers in it. Traditional Chinese is not
Simplified: `zh-Hant`, `zh-TW`, `zh-HK` and `zh-MO` fall through to the next
language the header offers rather than being served Simplified text.

Two kinds of text are localized, and they are stored differently:

- **Text we write.** Sidebar labels for a kind with no row yet, the Footage
  sub-shelves, the authoring form's own field titles and hints, the sign-in form
  at `api/auth/ui-schema/[flow]`, and every error message the app shows.
  `lib/i18n/messages.ts` holds them, English as the source; an untranslated key
  falls back to English rather than printing a key.
- **Text an admin writes.** Kind labels, category names, item titles and
  descriptions. Each table has a `translations` jsonb column keyed by locale
  then field — `{"zh-Hans": {"title": "…"}}` — and the base column stays the
  source. A field nobody has translated reads through to it, so a half-
  translated catalog shows the original rather than a blank or a guess. Nothing
  is machine translated.

Localized responses carry `Content-Language` and `Vary: Accept-Language`, which
is what stops a shared cache handing one language's answer to the next caller.
`q`-weights are honoured, so `en;q=0.3,zh-CN;q=0.9` is a Chinese request.

Searching follows the same rule: `GET api/v1/marketplace/items?q=` matches the
base title and description *and* the translation for the requesting locale, so
someone browsing in Chinese can find a shelf by typing Chinese.

The admin API is the deliberate exception. `GET api/v1/admin/marketplace/items`
and `…/items/[id]` return the text as it was typed, with `translations`
alongside it: an editor has to see what it is about to overwrite, not a
translation of it. Only the form's own labels follow `Accept-Language` there.
The form gets one box per translatable field per language, with ids that are
paths into the item — `translations.zh-Hans.title` — so adding a language is a
server change, not a release. Validation messages zod produces ("Pick a
category.") stay in the source language; they name a field rather than address
a reader.


## Admin authoring in the app and agent

Admins get two sidebar destinations backed by the same preview grid: **My
Marketplace** (their own drafts and published items) and **Manage Items**
(everything this account may manage). Both offer status filters, search and
pagination. The server filters by the authenticated author's `createdBy` before
counting and paginating (`GET /api/v1/admin/marketplace/items?scope=mine`).
Cards share the catalog's layout and play muted video previews on hover.
Refreshes keep the current cards visible beneath a loading overlay in both the
catalog and authoring grids. Edit, Publish/Unpublish and Delete live in each card's context menu, so a
destructive action is never one stray click away and the editor itself carries
no publishing controls; clicking a card opens the editor. Publishing uses the
existing content and preview validation; changes refresh the author's list and
catalog. **Create Item** remains in the toolbar. The editor supports
free-by-default credit pricing, categories, tags, content files or film assets,
generated covers/content, excerpt selection and preview jobs. Cover images and
playable video previews appear inside their respective form fields, alongside
preparation, upload and generation progress. Section help stays in footers,
with save status, errors, Done and Save Draft in the action bar. A generator or upload that
fails leaves its message in a "Needs Attention" section with a retry, and
raises it as an alert while the editor is open. Save Draft does not close the
editor: it confirms the draft is saved and offers My Marketplace, which is
where an item is published from. Effects and transitions have
native preset controls and an advanced descriptor editor. Catalog and draft
operations also work with no film open. Roles from `/api/v1/me` are decoded; the
admin capabilities endpoint and every authoring operation independently enforce
the administrator role.

**Create Marketplace Item…** starts a draft from a piece of the open film, for
admins. It appears on a library card, on a timeline clip, on a take in the
footage strip, and on every row of the **Show All Versions…** sheet — the same
`MarketplaceSeedHost` behind all six, so the gating, the progress while a seed
is prepared, the failure alert and the editor sheet exist once.

What a piece becomes is `MarketplaceKind.forFootage`: a clip or a still becomes
`footage`, audio becomes `audio`, and a Remotion composition becomes `remotion`.
Captions have no kind. A composition is the one thing that does not publish the
file in front of it: its content is a zip of the project — `src/`, `public/`,
the root config files and an `rxremotion.json` descriptor carrying the prompt,
canvas size, frame rate and duration. The archive's file list is
`RemotionProjectFiles.list`, the same walk the agent's `list_files` and the
source viewer use, so `node_modules`, `.agent-stills`, `.git`, `dist` and build
output never ship. Its listing preview is the render that was selected, and its
cover is frame 0 rendered natively — out of a round-trip of the archive rather
than the film's own project directory, which both keeps publishing from
mutating the film and proves the archive is complete before it is uploaded.

A `remotion` item is the first thing in the marketplace that is executable
rather than inert: installing one puts TypeScript on disk that the installing
Mac compiles and runs in a WebView. Authoring stays admin-only for that reason,
and `RemotionProjectArchive.read` validates the tree — no symlinks, nothing
resolving outside the root, no unexpected top-level entry, bounded file count
and size — before a byte reaches a film package. `MarketplaceStore.postInstall`
runs the same check at install time; the unpacking itself happens in
`MarketplaceInstaller.addToFilm`, because one installed archive can be added to
several films and each needs its own `remotionProjectDir`.

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
than failing the payload. Deleting an item is available in both and asks twice
in each — the app from the row's context menu, the website through a confirm
dialog that wants the word typed back — and the server still refuses once the
item has been bought.

`MarketplaceAuthoringService` is shared by the native editor and MCP handlers.
The website server actions and `/api/v1/admin/marketplace/*` share
`lib/marketplace/authoring.ts`. The REST surface includes capabilities, the
form schema, categories (list, create and rename), paginated item listing, item
create/update, structured content, upload authorization/finalization, asset
removal, item deletion, and publish/unpublish.
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
draft. Imported assets and Remotion compositions retain marketplace identity;
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

### Remotion compositions and footage media types

1. Apply `drizzle/0007_marketplace_remotion.sql`. It retires
   `marketplace_kind.remotion_prompt` outright — superseded by `remotion`,
   which carries the source rather than a prompt — deletes that kind's
   `marketplace_kinds` and `marketplace_categories` rows, and backfills
   `metadata.mediaType = "video"` on existing footage, which is correct by
   construction because MP4 and MOV were the only content types footage ever
   accepted. It is the one destructive step in this change, and it raises a
   named exception instead of proceeding if any `marketplace_items` row still
   uses the retired kind, leaving the database untouched.
2. Deploy the website before distributing the app. `catalog_version` 1 and 2
   responses are unchanged, and `remotion` is withheld below 3. That gate is
   load-bearing rather than cosmetic: a shipped build decodes the catalog page
   strictly, so one item of an unknown kind would fail the whole page. (This
   release also makes the app's catalog and purchases arrays lenient, so the
   next new kind will not need a version bump.)
3. Distribute the app, which asks for `catalog_version=3`.

Installs of the retired kind under `Marketplace/remotion_prompt/<itemId>/` are
left on disk rather than deleted on upgrade: nothing references them, the new
build does not scan that folder, and they cannot be reinstalled.

### Project templates

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
