# Image Generation

The Image tab generates still images — storyboard frames, thumbnails, style references, or anything
else you need a picture of. Every generation stays attached to the project that made it.

## Create a project

Click **+** above the sidebar, then fill in the form.

### Provider

Pick the provider first, because the parameters below it change to match.

- **OpenAI-compatible** uses the endpoint and key from **Settings › AI Provider**.
- **Google** uses your Google AI API key.

### Prompt

A free-text description of the image you want.

### Model

Each provider has its own model picker, populated from the endpoint. Use the refresh button next to
the picker to re-fetch the list — useful after changing your endpoint or when a provider adds a
model.

## Image parameters

The parameter section depends on the provider.

### Google

- **Aspect Ratio**
- **Resolution**

For landscape stills, a 5:4 ratio at 2K is a good starting point.

### OpenAI-compatible

- **Size** — a preset, or **custom** with explicit **Width** and **Height** in pixels.
- **Quality**
- **Format** — with a **Compression** percentage for the formats that use one.
- **Background**
- **Transparent background** — requires PNG or WebP output.

## Generate

**Generate** is in the toolbar. Results are added to the project's generated images.

Open **Generated Images** to browse everything the project has produced. Nothing is overwritten by a
new run, so you can iterate on a prompt and compare the results side by side.

## Using an image elsewhere

- Music and Remotion projects both accept **reference images**, which act as a visual style guide.
- The agent can generate images directly into a Remotion project — those land in the composition's
  `public/generated/` folder and are referenced with `staticFile("generated/<name>")`. See the
  Remotion section.

## Deleting

Deleting an image project permanently deletes the images it generated.
