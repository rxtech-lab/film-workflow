# Overview

Film Workflow is a production toolkit for short-form video. It generates the pieces a video is
built from — music, narration, captions, still images — and assembles them into a rendered
composition, all in one app. An agent can drive any of it for you.

## The tabs

Each tab is a workspace for one kind of asset. They all follow the same shape: a sidebar of
projects on the left, a settings form and a results list on the right, and the action that does the
work in the toolbar.

- **Music** — generate a track from a description, with an optional song structure and lyrics.
- **Narrative** — turn a written script into multi-speaker narration using text-to-speech.
- **Caption** — transcribe audio into captions, edit and retime them, translate them, and export
  WebVTT, SubRip, plain text or JSON.
- **Image** — generate still images for storyboards, thumbnails and reference.
- **Remotion** — build and render a video composition. **macOS only.**
- **Agent** — describe what you want in plain language and let the agent operate the app.
  On macOS this is its own window (Command-Option-0); on iPhone and iPad it is a tab.
- **Settings** — on iPhone and iPad, settings are a tab. On macOS they are in the app menu
  (Command-Comma).

## Projects and groups

Every tab organises work into **projects**. A project holds its own settings and everything
generated from them, so a music project keeps every take you made from it and a caption project
keeps every transcript version.

Create one with the **+** button above the sidebar. Right-click a project to rename, duplicate,
move or delete it.

Projects can be collected into **groups** — use **New Group** next to the **+** button, then drag
projects into it, or use **Move to Group** from a project's context menu. Groups are per tab.

Deleting a project deletes the files it owns. The confirmation dialog always says exactly what will
go with it.

## How the pieces fit together

The tabs are designed to feed each other:

- A narration generated in the **Narrative** tab can be used directly as the source of a
  **Caption** project. Captions made this way keep your exact wording — the speech service supplies
  only the timings — and the speakers come from your narrative rather than from voice detection.
- Music, narration and generated images can all be added to a **Remotion** project as assets and
  referenced from the composition.
- The **Agent** can create and edit projects in any tab on your behalf.

## Where files live

Generated audio, imported audio, images, caption files, downloaded Whisper models and Remotion
projects are all stored inside the app's own Application Support folder. Nothing is written into
your Documents folder unless you export it there yourself.

Exports always go through a save panel, so you choose the destination.

## Before you start

Hosted AI features can use **RxFilm credits** or your own provider credentials. Choose the mode in
**Settings › AI Provider › Credential mode**.

### Use RxFilm credits

1. Open **Settings › Account** and sign in with your RxLab account.
2. In **Settings › AI Provider**, choose **RxFilm credits** and select the default models.
3. On macOS, use **Account › Add Credits** when you need to top up. iPhone and iPad can use credits
   already on the account but do not link to an external purchase flow.

The app uses server-managed provider credentials in this mode. Hosted generations deduct their
actual metered usage from the account; the Account screen shows the available balance, reserved
credits for work in progress, and recent usage. If the balance is too low, the current operation
stops with an insufficient-credits alert instead of silently switching to your own keys.

### Bring your own keys

Choose **Bring your own keys** and fill in the credentials you need:

- **Google AI API key** — music generation, Gemini voices, Gemini transcription, Google image models.
- **Azure Speech** — Azure voices and Azure transcription. Paste your region, such as `eastus`, or
  any endpoint URL from the portal.
- **OpenAI-compatible endpoint and key** — the agent, caption AI tasks, OpenAI transcription and
  OpenAI image models. Works with OpenAI itself and with anything that speaks the same API, such as
  Azure OpenAI, OpenRouter, Ollama or LM Studio.

Keys are stored in the system Keychain, never in a plain file.

On-device Whisper, Apple Intelligence, Claude Code and Codex keep using their own local or CLI
runtime and do not spend RxFilm credits. See the Captions section for on-device Whisper.

## Getting help

- This guide is available at any time from the **Help** menu (Command-?) on macOS.
- **What's New** in the Help menu lists recently added features.
- Tips appear as small popovers next to controls the first time you reach them.
