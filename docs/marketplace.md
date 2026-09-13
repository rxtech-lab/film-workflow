# Marketplace

The **Marketplace** window (toolbar button, or ⌘⌥M) lists items an admin has
published on the website: footage, Remotion prompts, music, sound effects,
fonts, transitions and effects. Each item has a category, a preview image and
optionally a preview video, and a price in credits (0 = free).

## In the app

- The **What's New** sheet introduces Marketplace and the RxFilm subscription
  service once per feature card. Reopen it from **RxFilmStudio → What's New…**;
  **Explore Marketplace** closes the sheet and opens the catalog.
- Browse by kind and category with the filter chips above the grid; search filters the grid. Click a card to open its detail sheet; hovering a card with a video preview plays it in place, muted.
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
| `MarketplaceWindowView` (`views/marketplace/`) | Filter bar, grid with hover-autoplay cards, detail sheet with `VideoPlayer` preview; `#Preview`s run on a canned transport |

## On the website

`/admin/marketplace` (users whose IdP roles include `admin`) creates items,
uploads previews and content straight to R2 through presigned PUTs, edits
effect/transition descriptors in place, and publishes. The item form changes
with the kind: footage, music, sound effects, fonts and prompts get a content
file slot with kind-specific accepted types; effects and transitions get the
descriptor editor instead; preview video is offered only for visual kinds. On
a new item the files are staged and uploaded right after the draft is created.

Categories are rows in `marketplace_categories`, scoped to a kind and created
inline from the item form ("New" next to the category picker). Items reference
them by `category_id`; the wire keeps `category` as the slug (what the app
filters on) and adds `category_name` for display. Data lives in Neon Postgres
(`marketplace_categories`, `marketplace_items`, `marketplace_purchases`). The app talks to
`GET api/v1/marketplace/items`, `GET …/items/[id]`, `POST …/items/[id]/purchase`,
`GET …/items/[id]/download` and `GET api/v1/marketplace/purchases`.
