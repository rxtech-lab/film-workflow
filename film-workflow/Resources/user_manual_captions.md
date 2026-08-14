# Captions

The Caption tab turns audio into timed captions, and gives you the tools to correct, retime,
translate and export them.

## Pick a source

Create a caption project with **+**, then choose its audio in the **Audio source** section:

- **Import Audio…** — pick an audio file from disk.
- **Use Narration…** — pick a narration you already generated in the Narrative tab.

A narration source is the better option when you have one. Captions made this way use the speech
service **only for timings** — the caption text stays exactly as you wrote it — and speakers come
from your narrative instead of from voice detection.

Importing new audio replaces the old file and clears any alignment the project had.

## Choose a transcription provider

The **Transcription** section picks the provider for this project, or leaves it on the app default
from **Settings › Captions**.

- **Whisper (on device)** — runs entirely on this device with no network. Returns word timings.
  Does **not** detect speakers. Requires a downloaded model.
- **OpenAI-compatible** — uses the endpoint and key from **Settings › AI Provider**. Returns word
  timings with most models. Does not detect speakers.
- **Azure Speech** — detects speakers and returns word timings. The most capable option overall.
- **Gemini** — detects speakers but returns **no** word timings, and its timestamps sometimes need
  the timing fallback.

Under the picker, three badges show at a glance whether the selected provider supports **Speakers**,
**Word timings**, and working **Offline**.

Controls a provider cannot support are hidden rather than shown disabled, and the footer explains
what to do instead — for example, providers with no speaker detection tell you to assign speakers in
bulk from the editor.

### On-device Whisper

Whisper models are downloaded from Hugging Face and run locally, so audio never leaves the device.

Open **Settings › Captions › On-device Whisper models** to manage them:

- Each row shows the model's size, whether it is **Recommended**, and whether it is **English only**.
- The download button fetches a model; the progress is shown inline.
- Click the circle next to a downloaded model to make it the default.
- The trash button deletes a model from this device. You can download it again later.
- **Keep the model in memory between runs** trades memory for speed on repeated runs.
  **Unload model from memory** frees it immediately.

Larger models are more accurate and slower.

A project can override the global model with **Whisper model** in its own Transcription section,
choosing from what is actually downloaded. If nothing is downloaded, a **Download a Model…** button
takes you straight to the model list.

### Language and speakers

- **Language hint** — a code such as `en-US` or `zh-CN`. Leave it blank to auto-detect.
- **Detect speakers** — only shown for providers that support it, with a stepper for the maximum
  number of speakers.
- **Word-level timings** — only shown when the provider *and* the selected model can produce them.

Defaults for new projects live in **Settings › Captions › Defaults for new projects**.

### Timing fallback

**Settings › Captions › Providers › Timing fallback** names a second provider to re-run
transcription with when the first returns timings that go backwards. Set it to **None** to disable.

## Terms

The **Terms** section is a per-project glossary: names, jargon and anything else the model is likely
to get wrong.

For each term you can record its correct **Spelling**, a note saying what it is (`company name`,
`drug name`), **known mistakes** — spellings the transcriber has produced for it — and preferred
**translations** per language.

**Paste List** adds many at once, one per line or comma-separated.

Turn on **Use terms as a spelling hint when transcribing** in **Settings › Captions › Caption AI**
to feed them to the transcriber up front.

## Transcribe

The **Transcribe** button is in the toolbar. Progress is reported while it runs.

Re-transcribing does not destroy your work: it creates a **new version** and keeps the current one,
along with its translations.

After a run, the **Last transcription** section records when it ran and which provider was used.

## Edit the captions

The caption list shows every cue with its index, timing and text. Right-click a caption for:

- **Edit Text & Timing…** — change the wording and the in and out times.
- **Word Timings…** — inspect and adjust individual word times.
- **Split at Midpoint** and **Merge with Next**.
- **Delete…**

Select multiple captions to act on them together — this is how you assign speakers in bulk when the
provider did not detect them.

Icons in the list flag captions whose timing is **estimated** and show how many word timings a
caption carries.

### Retiming

**Open Retimer** brings up a dedicated retiming view. Play the audio and set boundaries as it runs —
the space bar sets the current boundary — or type an exact time. **Preview** plays the current
caption. **Close gaps shorter than 300 ms on save** tidies up small holes between cues when you
save.

### Caption length

**Settings › Captions › Caption length** controls how long captions are allowed to get:

- **Splitting** chooses between a plain **character limit** and **AI** splitting.
- The character-limit mode applies only to runs of text with no sentence punctuation. Commas never
  split a caption.
- The AI mode asks the model where a long caption should break — at a clause boundary, never
  mid-phrase, and never leaving a stub second line. It leaves a caption alone when no split improves
  it.

## Caption AI

**Settings › Captions › Caption AI** picks the engine used for splitting, for checking captions
against the project's terms, and for the caption assistant.

- **Apple Intelligence** runs entirely on this device.
- **OpenAI-compatible** uses your provider settings.
- **Claude Code** and **Codex** read a saved transcript through the app's own MCP server, so they
  can split and check terms from the caption editor. They cannot do it *during* transcription, when
  the captions do not exist yet — that pass falls back to Apple Intelligence or an
  OpenAI-compatible model.

**Review AI changes before applying** is on by default. With it on, AI edits arrive in a **Review AI
Changes** sheet listing each proposed change with a checkbox. Use **Select All** / **Select None**,
then **Apply** the ones you want or **Discard** the lot.

## Translate

**Translate…** opens the translation sheet.

- **Translate into** — pick a language, or choose **Other…** and enter a BCP-47 code such as
  `zh-Hans`, `es` or `ja`. The sheet tells you what language the captions are currently in, and
  what produced the last translation.
- **Engine** — **Apple Translation** runs on device once the language pair is installed;
  the **AI backend** routes it through your AI provider, which handles context better.
- **Follow the project glossary** (AI engine only, set in **Settings › Captions › Translation**)
  keeps your terms consistent.
- **Scope** — translate only the selected captions, and choose whether to re-translate captions that
  already have a translation.

Translations requested by an outside agent over MCP always use the AI backend, because Apple's
engine only runs inside the app.

In the caption list, the **Translation** picker switches between **Original only** and any language
you have translated into. A marker flags captions that changed after they were translated.

Removing a translation deletes every caption's translation in that language for the current
version, including any you edited by hand.

## Export

**Export** in the toolbar opens the export sheet, with a live preview of the output and its size.

- **Format** — WebVTT (`.vtt`), SubRip (`.srt`), Plain text (`.txt`) or JSON (`.json`).
- **Granularity** — sentence, word, or word karaoke. Formats that cannot express inline word timings
  fall back to sentence cues, and the sheet says so.
- **Speaker names** — how speakers appear. Voice tags are WebVTT-only; elsewhere names are used as a
  prefix.
- **Plain text** can optionally include timestamps.
- **Remove punctuation** and **Re-wrap over N characters** clean up the text on the way out.
- **Language** and **Layout** appear once the project has translations — export the original, one
  translation, or both together.

Three buttons at the bottom go beyond a single file:

- **Copy** puts the rendered output on the clipboard.
- **Save All Formats…** (macOS) writes VTT, SRT and TXT into a folder in one go.
- **Export Each Language…** writes one file per language, named `{project}_{language}.{ext}`.

Translations have no word timings, so translated exports use whole-sentence cues and long captions
are not re-wrapped.

## Narrative alignment

When a caption project came from a narration, an **Narrative alignment** section reports how well it
matched:

- **Alignment** — word aligned, sentence aligned, estimated, or not aligned.
- **Script match** — how much of your text the speech service recognised. Higher means more accurate
  timings.
- **Script paragraphs** — how many paragraphs the script contributed.

**Settings › Captions › Narrative alignment** sets the **Alignment confidence** threshold: how much
of your script must match what the speech service heard before per-word timings are trusted. Below
that, timings fall back to whole sentences.

## Deleting

Deleting a caption project permanently deletes its transcript versions and any audio it owns.
