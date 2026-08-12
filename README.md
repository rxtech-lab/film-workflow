# film-workflow

`film-workflow` is a SwiftUI app for organizing and generating music for film projects using Google AI (Lyria).

## Features

- Create and manage multiple music projects
- Configure musical parameters (genre, mood, BPM, key, duration, instruments)
- Choose generation mode:
  - **Editor**: define song structure and optional timestamped lyrics
  - **Prompt**: provide free-form prompt instructions
- Attach up to 10 reference images per project
- Preview the full generated prompt before sending
- Generate audio (and optional lyrics) through Google AI Lyria
- Play, review, export, and delete generated tracks from history
- Secure API key storage in Keychain

## Project Structure

- `film-workflow/` – main app source (SwiftUI views, models, clients, utils)
- `film-workflowTests/` – unit tests
- `film-workflowUITests/` – UI tests
- `film-workflow.xcodeproj/` – Xcode project
- `scripts/ci/` – release scripts (signing, notarization, Sparkle appcast)
- `Info.plist` – extra keys merged into the generated Info.plist (Sparkle feed + public key)

## Requirements

- macOS with Xcode (latest stable recommended)
- iOS simulator/device or macOS target supported by the project
- Google AI API key with access to Lyria

## Getting Started

1. Open `film-workflow.xcodeproj` in Xcode.
2. Select your target (iOS or macOS) and run the app.
3. Open **Settings** and save your Google AI API key.
4. Create a new music project from the **Music** tab.
5. Configure parameters and click **Generate**.

## Data & Storage

- App data is stored using SwiftData.
- Generated audio and imported reference images are saved under app support directories:
  - `com.rxlab.film-workflow/generated`
  - `com.rxlab.film-workflow/images`

## Testing

Run tests in Xcode (`Product > Test`) or via command line on a machine with Xcode tools installed.

Example:

```bash
xcodebuild test -project film-workflow.xcodeproj -scheme film-workflow -destination 'platform=iOS Simulator,name=iPhone 15'
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
