# Agent

The agent operates the app for you. Describe what you want in plain language — "make a 30 second
upbeat track and drop it into the intro composition", "check these captions against the glossary" —
and it calls the same tools the UI does.

On macOS the agent is its own window: **Command-Option-0**, the **Agent** item in the menu, or the
sparkle button in the toolbar. A dot on that button means a turn is running. On iPhone and iPad it
is a tab.

## Threads

Work is organised into **threads**. Each thread keeps its own history and its own settings, and
several threads can run at once — the thread list shows how many are currently working.

- **New thread** is the **+** button above the thread list.
- Deleting a thread permanently deletes its messages and its saved summary. **The film is not
  affected.**

### Targets

Every thread targets one item in the film's library — a music, narration, captions, image, video
or Remotion item, or a sequence — or the whole film. The composer shows the current target, and you
change it there or by typing **@** and picking an item. The target is a property of the thread, not
of the app, so changing the library selection while a turn is running cannot retarget it. A thread
with no target shows **Whole film**.

New threads are seeded with whatever you are currently looking at, which is usually what you want.

## Engines

**Settings › Agent › Engine** sets the default engine, and each thread can override it from the
picker in its composer.

- **Apple Intelligence** — runs entirely on device. It **cannot call tools**, so it can answer
  questions but not change your film. Caption edits are the exception: it can still propose those.
- **OpenAI-compatible model** — uses the endpoint, key and model from **Settings › AI Provider**.
  Full tool access.
- **Claude Code** — the `claude` command-line tool, talking back to the app over its own MCP server.
  **macOS only.**
- **Codex** — the `codex` command-line tool, the same arrangement. **macOS only.**

The CLI engines require the corresponding tool to be installed on your Mac. When an engine is
unavailable, the settings pane says why rather than hiding the option — an explanation you can act
on is more useful than a missing row.

The app's MCP server starts automatically when a thread needs it, so the CLI engines work without
you turning anything on.

## Permissions

**Settings › Agent › Permissions › Caption edits** controls how caption changes are applied:

- **Review before applying** (the default) — the agent proposes caption edits and you approve them.
- **Apply immediately** — caption edits take effect as soon as the agent makes them.

Everything else the agent does — adding footage, editing compositions, generating takes, cutting a
sequence — takes effect immediately under either setting.

With review on, proposals arrive in the **Review AI Changes** sheet in the Caption tab. Each change
has a checkbox; **Select All** / **Select None** help with long lists; **Apply** commits the checked
ones and **Discard** throws them all away.

## Limits

**Settings › Agent › Limits › Tool rounds per turn** caps how many times the agent may call tools
before it has to answer. Raise it for long jobs; lower it to cut a looping model short sooner.

## Composing

Type in the composer and send. While a turn is running the composer shows **Working…** and a stop
button.

Messages sent during a running turn are **queued** rather than dropped. The composer shows how many
are waiting and offers **Send all as one** so you can merge them into a single follow-up.

The agent's replies render as formatted text, including code blocks.

## What the agent can do

The agent reaches the app through the same tools the MCP server exposes, so its capabilities line up
with the editor:

- **Library** — list, read, create, update, duplicate and move footage items; import files; manage
  folders.
- **Generation** — generate music, narration, images and video as new takes.
- **Sequences** — create a sequence, put takes on its tracks, rearrange clips, and render it.
- **Captions** — create a captions item, transcribe, list and search captions, update them, set
  speakers, propose edits, translate, manage versions and export.
- **Remotion** — list, read, write and edit a composition's files, add and remove images and audio,
  generate images into it, and take screenshots of it.

Deleting footage or folders is never offered to the agent; use the library for that. The rest
depends on the write policy above: under **Review before applying**, the direct caption-writing
tools are withheld and only the proposal tool is available.

For the full list and how to reach the same tools from your own software, see the MCP Server
section.
