# Music

The Music tab generates a track from a description. You set the mood and the musical parameters,
optionally lay out a song structure and write lyrics, and the app builds the prompt and generates
the audio.

Music generation uses your **Google AI API key**. Set it in **Settings › AI Provider** before your
first run.

## Create a project

Click **+** above the sidebar to create a music project, then fill in the form in the **Prompt**
pane.

### Basic info

- **Project Name** — how it appears in the sidebar.
- **Input Mode** — how you want to describe the track.

### Overall vibe

A free-text description of the feeling or atmosphere you are after. This goes at the top of the
generated prompt, so it sets the tone for everything else.

### Musical parameters

- **Genre** and **Mood**
- **BPM** — chosen from presets rather than typed.
- **Key / Scale**
- **Duration**
- **Type** — instrumental, or with lyrics.
- **Output Format** — the audio format the track is delivered in.
- **Lyrics Language** — appears only when the type is set to with-lyrics.

### Instruments

A grid of instruments you can switch on and off. Selected instruments are named in the prompt.

### Reference images

You can attach up to **10** reference images to a project. On macOS, use **Add Images** to pick
files. On iPhone and iPad, **Add Images** offers both your photo library and the Files app.

Removing an image deletes the stored copy — the confirmation dialog says so.

## Song structure and lyrics

Switch to the **Song Structure** pane to lay out the track section by section — verse, chorus,
bridge and so on. Add a section with the **+** buttons above the list, then reorder sections with
the up and down controls (or the **Move Up** / **Move Down** context-menu items).

The **Lyrics** pane is only enabled when the generation type is set to **With Lyrics**. If the
lyrics editor tells you it is unavailable, go back to the Prompt pane and change the type.

## Generate

**Generate** is in the toolbar. Before the run starts you get a **Prompt Preview** showing the
exact prompt that was assembled from your settings — this is your chance to check the parameters
produced what you meant. Confirm with **Start Generation**, or cancel and adjust.

Every run is kept. Open **History** in the toolbar to see the takes this project has produced,
play them back, and export the ones you want.

Because takes accumulate, it is worth generating a few variations before settling. Nothing is
overwritten.

## Playback and export

Generated tracks play inside the app. Use the export action on a take to save it to disk.

## Using a track in a video

A generated track can be added to a Remotion project as an audio asset — see the Remotion section.
Audio added there is copied into the composition's `public/audio/` folder and referenced with
`staticFile("audio/<name>")`.

## Deleting

Deleting a music project permanently deletes its generated audio and its reference files along with
it.
