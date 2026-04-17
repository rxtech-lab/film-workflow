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

## Notes

- The **Narrative** tab is currently a placeholder (`Coming soon`).
