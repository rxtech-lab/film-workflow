# The `.rxfilmstudio` film package

Every film is a package directory (Finder shows it as one file) that holds the
film's SwiftData store and all media generated for it. The app owns the
store directly rather than going through SwiftUI's `DocumentGroup`: Apple
does not support a SwiftData document that is also a package with sidecar
files, and writing media into such a package corrupts the store.

```
My Film.rxfilmstudio/
├── Document.json                 { id, formatVersion, createdAt, appVersion }
├── Workspace.json                optional per-film panel sizes
├── Library.store (+ -wal/-shm)   SwiftData: projects, outputs, groups, sequences, renders, imports
├── Media/
│   ├── Music/       generated music
│   ├── Narration/   generated narration
│   ├── Images/      generated images, poster frames, reference images
│   ├── Videos/      generated video clips
│   ├── Captions/    imported caption audio and exports
│   └── Imported/    files copied in from Finder
├── Remotion/<projectId>/         src/, public/, configs; node_modules is a symlink
│                                 to the shared runtime in Application Support
├── Renders/
│   ├── Remotion/<projectId>/vNNN-<hash8>.mp4   render cache, keyed by source hash
│   └── Sequences/<sequenceId>/vNNN.mp4         sequence versions
└── Cache/Thumbnails/
```

## Code map

| Type | Role |
|---|---|
| `ProjectDocument` (`document/`) | Owns the `ModelContainer` at `Library.store` and the `ProjectStorage` for one package. |
| `ProjectDocumentController` | Open documents, the active one, New/Open/Recent panels, Finder open requests. |
| `ProjectStorage` | Package layout and media helpers. Resolved from a `ModelContainer` (`forContainer`) or a model (`for(model:)`), so services keep their `ModelContext` signatures. |
| `AppModelContainer` | App-level store (`Agent.store` in Application Support) for agent threads, which span films. |
| `DocumentMediaResolver` | Maps timeline source ids (`video:<uuid>`, `remotion:<uuid>`, …) to files and caption cues. |
| `SequenceRenderService` | Renders stale Remotion clips, then exports the timeline through the `RxVideoEditor` package. |

## Panel layout

Editor panel sizes travel with the film in `Workspace.json`: library and
inspector widths, the viewer/timeline split, and the library/footage split.
Divider changes save automatically (debounced during dragging) and flush on
close or quit. Reopening restores the layout within the current window's size
constraints; sidebars keep their widths and vertical splits keep their proportions.
Older films and missing or unreadable workspace files use the default layout.
This optional file does not change the document format version.

## What stays global

`~/Library/Application Support/com.rxlab.film-workflow/` keeps the Remotion
runtime (`bun`, `node_modules`, template configs), Whisper models, scratch
space (`tmp/`, cleared at launch), the agent store and two JSON caches.

## Caveats

- Saves happen in place as SwiftData autosaves, plus an explicit flush when a
  window closes and at quit. Close the film before copying or syncing the
  package; a copy taken mid-write can carry an inconsistent `-wal` file.
- Referenced imports (Finder files left in place) are stored as bookmarks.
  The app is not sandboxed, so a plain bookmark is used when a
  security-scoped one cannot be created.
- `RemotionRender.sourceHash` covers `src/**`, the three config files, the
  output size and frame rate, and the path, size and modification time of
  everything under `public/`. Logs, `node_modules` and bundler caches are
  ignored.
