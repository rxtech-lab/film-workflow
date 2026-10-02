# Background rendering and caption export feature artwork

Two transparent PNG illustrations generated with the built-in image generation
tool for the **Background rendering** and **Captions in your exports** What's
New cards. Both use the existing navy, cobalt, lavender, peach and cream
palette and a wide 2:1 composition for the native card's 192-point artwork area.

Assets:

- `film-workflow/Assets.xcassets/WhatsNewRenderQueue.imageset/render-queue.png`
- `film-workflow/Assets.xcassets/WhatsNewCaptionExport.imageset/caption-export.png`

## Feature copy sources

- `7505bfd` — **feat: add rendering queue support and marketplace web**:
  app-wide background rendering with separate composition, thumbnail and
  waveform concurrency limits; queue progress and retained composition failures;
  a dedicated Captions tab and optional caption files alongside burned-in or
  embedded movie captions.
- `6ce333e` — **feat: redesign ui using video editor style (#28)**:
  caption delivery in sequence renders, with original/translated/bilingual
  burn-in, embedded subtitle tracks, and SRT/VTT files.

The queue illustration shows media preparation in the app; it does not imply a
remote rendering service or a queue for final movie exports. The caption
illustration shows subtitle bars inside the finished video and companion files.
Existing card IDs and artwork are preserved so their read state survives updates.

## Final prompt: background rendering

Use case: stylized-concept
Asset type: transparent hero illustration for the Background rendering What's New card in RxFilmStudio, a native macOS filmmaking app.
Primary request: Create a polished flat 2D editorial illustration representing background media rendering while editing continues. A warm-cream rounded queue panel with deep navy outline shows three generous rows: a small cobalt film-composition tile with a play triangle and a mostly filled cobalt progress bar; a peach landscape thumbnail with a shorter lavender progress bar; a navy audio waveform with an empty cream progress track outlined in lavender. Beside and slightly behind this panel is a compact editing timeline with two rows of cobalt and lavender clip blocks and one peach playhead. A small circular cobalt motion arrow near the film tile communicates ongoing processing. Queue panel is the focal point; no cloud or server.
Style/medium: vector-like crisp clean edges, bold deep navy outlines, softly rounded shapes, simple solid fills, front view. Match an existing creative-app announcement illustration set.
Color palette: deep navy, vivid cobalt blue, soft lavender, peach, and warm cream.
Composition/framing: wide 2:1 canvas, centered compact balanced artwork with 8 percent clear outer margins, large simple shapes legible at 384 by 192 points. Use the height well without cropping.
Background: actual transparent alpha channel, completely empty outside and between isolated objects, PNG cutout suitable for light and dark macOS surfaces.
Constraints: artwork only, no screenshot, no words, no letters, no numbers, no logos, no watermark, no backdrop rectangle, no checkerboard, no floor, no pedestal, no photorealism, no 3D, no drop shadows, no gradients.

## Final prompt: caption export

Use case: stylized-concept
Asset type: transparent hero illustration for the Captions in your exports What's New card in RxFilmStudio, a native macOS filmmaking app.
Primary request: Create a polished flat 2D editorial illustration representing captions traveling into a finished video. The main object is a rounded deep navy video preview panel containing a simplified peach sunset over vivid cobalt ocean, warm cream sun and reflections, navy coastal silhouettes. Across the bottom of the video are two short warm-cream horizontal subtitle placeholder bars on a dark navy rounded band, clearly inside the video. Below the panel is a short two-row editing timeline of cobalt and lavender clips. Beside the video sit two small overlapping cream caption-document sheets with navy outlines and two or three lavender placeholder lines each. One small cobalt curved arrow travels from the timeline toward the video, communicating caption export. One subtle lavender speech bubble with two cream placeholder bars suggests original and translated text. Keep the video dominant and the overall composition simple.
Style/medium: vector-like crisp clean edges, bold deep navy outlines, softly rounded shapes, simple solid fills, front view. Match an existing creative-app announcement illustration set.
Color palette: deep navy, vivid cobalt blue, soft lavender, peach, and warm cream.
Composition/framing: wide 2:1 canvas, centered balanced artwork with 8 percent clear outer margins, large simple shapes legible at 384 by 192 points. Use height well without cropping.
Background: actual transparent alpha channel, completely empty outside and between isolated objects, PNG cutout suitable for light and dark macOS surfaces.
Constraints: artwork only, no screenshot, no words, no letters, no numbers, no logos, no watermark, no backdrop rectangle, no checkerboard, no floor, no pedestal, no photorealism, no 3D, no drop shadows, no gradients.
