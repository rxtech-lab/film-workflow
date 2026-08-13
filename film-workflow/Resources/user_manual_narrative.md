# Narration

The Narrative tab turns a written script into spoken audio. You assign a voice to each speaker,
write the script paragraph by paragraph, and the app generates and stitches the narration into a
single track.

## Choose a provider

Open a narrative project and set **Provider** in the **Basic Info** section:

- **Azure Speech** — a large catalogue of voices grouped by language, with fine control over pitch,
  rate, volume, speaking role and style degree. Supports multiple speakers per narration. Lets you
  pick the **Output Format**.
- **Gemini** — a smaller set of expressive voices, driven by natural-language delivery cues.
  Supports **up to 2 speakers** per narration.

Switching providers keeps each speaker's voice choice for both providers, so you can switch back
and forth without losing your casting. Per-paragraph emotion cues are cleared on a switch, because
they are provider-specific.

Azure needs a **Subscription key** and a **Region or endpoint** in **Settings › AI Provider**.
Gemini uses the **Google AI API key**.

## Scene, notes and context

With Gemini selected, a **Scene** section appears with three free-text fields — **Scene
Description**, **Notes** and **Context**. These give the model background about the situation being
performed. They are not read aloud.

## Cast your speakers

The **Speakers** section is where you name each speaker and pick their voice.

- **Add Speaker** appends a new speaker with an unused voice. It disappears once you reach the
  provider's limit.
- The preview button next to each voice picker plays a sample so you can compare before committing.
- Deleting a speaker does not delete their lines: their paragraphs are reassigned to the first
  remaining speaker. You cannot delete the last speaker.

### Azure voice parameters

With Azure, each speaker has a **Voice parameters** disclosure holding:

- **Pitch**, **Rate** and **Volume** — accept the same values SSML does, such as `medium`, `+10%`,
  `-2st`, `0.9` or `+6dB`. Each field has a menu of suggested values.
- **Role** — the speaking role the voice adopts.
- **Style degree** — how strongly the style is applied, from 0.01 to 2.0.

**Reset parameters** clears all of them back to the defaults. A summary of anything non-default is
shown next to the disclosure label, so you can see at a glance which speakers have been tuned.

If the Azure voice list is empty, check your Azure credentials in Settings and use **Retry**.

## Write the script

The **Transcript** pane holds the script as a list of paragraphs, each assigned to a speaker. Use
the **+ speaker name** buttons to append a paragraph for that speaker.

### Shortcodes

Shortcodes are inline cues written in double braces that control delivery. Insert them from the cue
picker rather than typing them, and the app will show the right parameter fields for each one.

They fall into five groups:

- **Pauses and silence** — `{{pause}}`, `{{break:250ms}}`, `{{break:500ms}}`, `{{break:1000ms}}`.
  Azure also has `{{break:strong}}` and `{{silence:leading:300ms}}`; Gemini has `{{breath}}`.
- **Emotion and delivery** — Gemini only: `{{whispers|text}}`, `{{excited|text}}`, `{{sad|text}}`,
  `{{laughs}}`, `{{sighs}}`, `{{gasps}}`.
- **Emphasis** — Azure only: `{{emphasis:strong|text}}` and `{{emphasis:moderate|text}}`.
- **Say-as and pronunciation** — Azure only: `{{spell|W3C}}`, `{{say:date:mdy|10/15/2024}}`,
  `{{say:cardinal|1234}}`, `{{say:telephone|555-0199}}`, `{{phoneme:ipa:təˈmeɪtoʊ|tomato}}`,
  `{{sub:World Wide Web Consortium|W3C}}`.
- **Language and markers** — Azure only: `{{lang:de-DE|Guten Tag}}` for a temporary language switch
  on a multilingual voice, and `{{bookmark:scene1}}` for a named marker in the audio stream.

The cue picker only offers the shortcodes your current provider supports. Codes that wrap text
apply to the text you have selected.

Click an existing shortcode chip in a paragraph to edit its parameters, or delete it from the same
menu.

## Generate

**Generate** is in the toolbar. A preview of the assembled transcript is shown first — long scripts
are truncated in the preview but generated in full — then **Start Generation** begins the run. A
progress view reports where it is.

Segments are stitched into a single narration file automatically. Every run is kept: open
**History** in the toolbar to play back or export earlier narrations.

## Generate captions at the same time

The **Captions** section of the project form has **Generate captions with the audio**. When it is
on, a caption project is produced alongside the narration and appears in the Caption tab.

This is the most accurate way to get captions, because the caption text is your own script — the
speech service is used only as a clock — and speakers come from your speaker list rather than from
voice detection.

- **Caption provider** lets this project override the app default. If you pick a provider that does
  not return word timings, a warning appears: those timings will be estimated. Azure or on-device
  Whisper are much more accurate here.
- The resulting captions can be edited and exported like any other — see the Captions section.

## Deleting

Deleting a narrative project permanently deletes its generated audio.
