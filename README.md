# film-workflow

`film-workflow` (RxFilmStudio) is a macOS app for making short films from
generated footage. It generates music, narration, captions, images, video
clips and Remotion compositions, and assembles them on a timeline that renders
to mp4 — laid out like Final Cut Pro: a footage library on the left, a viewer
in the centre, an inspector with each workflow's parameters, Generate button
and versions on the right, and the sequence timeline along the bottom.

Each film is a `.rxfilmstudio` package holding its own SwiftData store and all
generated media. See `docs/document-package.md`.

## Features

- One document per film: New/Open/Recent, Finder double-click, several films open at once
- Footage kinds: Music (Lyria), Narration (Gemini/Azure TTS), Captions
  (Whisper/Azure/OpenAI), Images, Video (Veo), Remotion compositions, imported files
- Every generation is kept as a version; Remotion renders are cached by source hash
- Timeline: drag footage from the library, trim, move, split; captions burn in
- Render: Remotion clips are rendered first, then the sequence exports as a new
  version in the film or to a folder, with codec, audio, resolution and format options
- An embedded MCP server and agent window that can build and render films
  (`footage_list`, `sequence_add_clip`, `sequence_render`, …)

## Project Structure

- `film-workflow/` – app source (SwiftUI views, models, clients, document layer)
- `Packages/RxVideoEditor/` – the video editor package: `VideoEditorCore`
  (timeline model, AVFoundation composition and export) and `VideoEditorUI`
  (timeline, viewer, inspectors)
- `film-workflowTests/` – app unit tests; `Packages/RxVideoEditor/Tests` – package tests
- `film-workflow.xcodeproj/` – Xcode project
- `scripts/ci/` – release scripts (signing, notarization, Sparkle appcast)
- `Info.plist` – extra keys merged into the generated Info.plist (Sparkle feed, document types)

## Requirements

- macOS 26.2 or later with Xcode 26
- Provider keys in Settings, or an RxLab subscription

## Getting Started

1. Open `film-workflow.xcodeproj` in Xcode and run the macOS target.
2. Create a film from the Welcome window (**New Film…**).
3. Add footage with the **New** menu, set parameters in the inspector and click **Generate**.
4. Create a **Sequence**, drag footage onto its timeline, and click **Render**.

Launch argument `-skipStartupAuth` skips the keychain read at startup, which
is useful for unattended debug launches.

## Data & Storage

- Film data and media live inside each `.rxfilmstudio` package.
- The Remotion runtime, Whisper models, scratch files and the agent store live
  under `~/Library/Application Support/com.rxlab.film-workflow`.

## Testing

```bash
xcodebuild test -project film-workflow.xcodeproj -scheme film-workflow -destination 'platform=macOS' -only-testing:film-workflowTests
swift test --package-path Packages/RxVideoEditor
```

## Releases & Auto-Update

The macOS app updates itself with [Sparkle](https://sparkle-project.org). The
feed lives at `https://update.filmstudio.rxlab.app/appcast.xml`, published to GitHub
Pages, and every update is verified against the EdDSA public key baked into
`Info.plist`.

Cutting a release:

1. Run the **Create Release** workflow (`workflow_dispatch`). semantic-release
   reads the commit history, tags, and publishes a GitHub release.
2. Creating that release triggers **Build & Release**
   (`.github/workflows/build.yaml`), which on the self-hosted macOS runner:
   - sets `MARKETING_VERSION` from the tag and archives the app;
   - signs the Sparkle framework's helpers and re-seals the app with the
     Hardened Runtime (`scripts/ci/sign-sparkle.sh`);
   - builds `RxFilmStudio.dmg`, notarizes and staples it
     (`scripts/ci/notary.sh`);
   - generates and signs `appcast.xml` (`scripts/ci/generate-appcast.sh`);
   - uploads the DMG to the release and deploys the appcast to GitHub Pages.

Users get the update on next launch, or via **RxFilmStudio → Check for
Updates...**.

Required secrets (org- or repo-level):

| Secret | Purpose |
| --- | --- |
| `SPARKLE_KEY` | EdDSA private key signing the appcast; its public half is `SUPublicEDKey` in `Info.plist` |
| `BUILD_CERTIFICATE_BASE64` / `P12_PASSWORD` | Developer ID certificate imported into the runner keychain |
| `SIGNING_CERTIFICATE_NAME` | Identity name passed to `codesign` |
| `APPLE_ID` / `APPLE_ID_PWD` / `APPLE_TEAM_ID` | Notarization credentials (`APPLE_ID_PWD` is an app-specific password) |
| `RELEASE_TOKEN` | PAT used by semantic-release, so the created release triggers the build workflow |

Rotating the Sparkle key means updating `SPARKLE_KEY` **and** `SUPublicEDKey`
together — apps already in the wild trust the old public key, so a mismatched
pair silently stops updates from installing.

## Notes

- The **Narrative** tab is currently a placeholder (`Coming soon`).
