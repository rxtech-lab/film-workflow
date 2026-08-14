# Video Generation

The Video tab generates clips from a prompt, optionally starting from an image.
It follows the same vertical slice as every other tab — `VideoGenProject` /
`GeneratedVideo` → `VideoGenEnums` → `VideoGenClient` → `VideoGenerationService`
→ `views/videogen/*` — with three differences forced by the provider APIs:

1. Generation is **asynchronous**: submit → poll → download, not one request.
2. The provider's job handle is **persisted** on the project, so quitting or
   cancelling never loses a generation that has already been billed.
3. Option availability is **gated per model**, because Veo's parameter support
   differs between families and the API rejects invalid combinations.

## Provider: Google Veo (Gemini API)

The only provider wired today. Uses the Google AI key from
Settings → AI Provider.

### Submit

```
POST https://generativelanguage.googleapis.com/v1beta/models/{model}:predictLongRunning
x-goog-api-key: <key>
Content-Type: application/json
```

```json
{
  "instances": [{
    "prompt": "A paper plane looping over a city at dusk",
    "image":     { "inlineData": { "mimeType": "image/png", "data": "<base64>" } },
    "lastFrame": { "inlineData": { "mimeType": "image/png", "data": "<base64>" } },
    "referenceImages": [
      { "image": { "inlineData": { "mimeType": "image/png", "data": "<base64>" } },
        "referenceType": "asset" }
    ]
  }],
  "parameters": {
    "aspectRatio": "16:9",
    "resolution": "720p",
    "durationSeconds": "8",
    "personGeneration": "allow_all",
    "numberOfVideos": 1,
    "generateAudio": true,
    "seed": 12345,
    "negativePrompt": "text overlays, watermarks"
  }
}
```

Response: `{ "name": "models/…/operations/…" }`. That name is the job handle —
`VideoGenerationService` writes it to `VideoGenProject.pendingJobID` and saves
the context before anything blocks.

### Poll

```
GET https://generativelanguage.googleapis.com/v1beta/{operation_name}
x-goog-api-key: <key>
```

Returns `{"done": false}` until it finishes, then:

```json
{
  "done": true,
  "response": {
    "generateVideoResponse": {
      "generatedSamples": [
        { "video": { "uri": "…", "mimeType": "video/mp4" } }
      ]
    }
  }
}
```

A failure surfaces as `error.message`, which the client raises as
`VideoGenError.jobFailed` — the one case (with `noVideoInResponse`) that clears
the pending job, since retrying it can never help.

`VideoGenClient.awaitGoogleCompletion` polls with 3s → 10s backoff and a
20-minute deadline, checking `Task.checkCancellation()` first each iteration.
This mirrors `GeminiTranscriptionClient.waitUntilActive`.

### Download

`GET <video.uri>` with the same `x-goog-api-key` header. **The URI redirects to
a signed storage host and URLSession strips custom headers across that hop**, so
`AuthPreservingRedirectDelegate` re-applies the key in
`willPerformHTTPRedirection`. Without it the download returns 403.

### Capability matrix

Model ids are never hardcoded — the picker is fed from
`GoogleModelsClient.veoModels`, which filters on
`supportedGenerationMethods` containing `predictLongRunning`. Google renames
these between previews (`veo-3.1-generate-preview` → `veo-3.1-generate-001` → …),
so `VeoModelFamily.from(_:)` only *classifies* whatever the API returned.

| Family | resolution | durationSeconds | numberOfVideos | seed | audio | referenceImages |
|---|---|---|---|---|---|---|
| `veo-3.1`, `veo-3.1-fast` | 720p, 1080p, 4k | 4, 6, 8 | 1 | ✓ | ✓ | ✓ |
| `veo-3.1-lite` | 720p, 1080p | 4, 6, 8 | 1 | ✓ | ✓ | ✗ |
| `veo-3`, `veo-3-fast` | 720p, 1080p | 4, 6, 8 | 1 | ✓ | ✓ | ✗ |
| `veo-2` | 720p | 5, 6, 8 | 1–2 | ✗ | ✗ | ✗ |
| unrecognised | 720p, 1080p | 4, 6, 8 | 1 | ✓ | ✓ | ✗ |

Cross-constraints:

- 1080p and 4k render **8-second clips only**.
- Reference images require an **8-second** clip.
- `aspectRatio` is `16:9` or `9:16`.
- Video extension (not implemented) is limited to 720p.

`VeoModelFamily.clamp(_:)` enforces all of this. The parameters form calls it on
every model and resolution change, and `applyVideoFields` calls it after an MCP
`update_project` has applied every key — an agent can set fields in any order, so
the combination is only legal once they have all landed.

## Option vocabulary

The app's option model deliberately follows Vercel AI Gateway's provider-agnostic
vocabulary, so a second provider maps onto the same fields.

| App / AI Gateway | Google Veo | OpenAI-compatible `/v1/videos` |
|---|---|---|
| `prompt` | `instances[].prompt` | `prompt` |
| `duration` (seconds) | `parameters.durationSeconds` (string) | `seconds` |
| `aspectRatio` (`"{w}:{h}"`) | `parameters.aspectRatio` | — (implied by `size`) |
| `resolution` | `parameters.resolution` (`720p`/`1080p`/`4k`) | `size` (`"{w}x{h}"`) |
| `generateAudio` | `parameters.generateAudio` | — |
| `seed` | `parameters.seed` | — |
| `n` | `parameters.numberOfVideos` | — |
| `frameImages[first_frame]` | `instances[].image` | `input_reference` |
| `frameImages[last_frame]` | `instances[].lastFrame` | — |
| `inputReferences` | `instances[].referenceImages` | — |
| — | `parameters.negativePrompt` | — |
| — | `parameters.personGeneration` | — |

## Why not Vercel AI Gateway

AI Gateway serves Veo, Kling, Wan, Grok Imagine and Seedance behind one API — but
**video generation there is only reachable through the TypeScript AI SDK v6**
(`experimental_generateVideo`, plus its `poll` / `doStart` / `doStatus` /
`webhookUrl` job flow). Its documented REST surface at
`https://ai-gateway.vercel.sh/v1` is limited to:

- `GET /v1/models`
- `GET /v1/models/{creator}/{model}/endpoints`
- `GET /v1/credits`
- `GET /v1/generation`
- `GET /v1/report`

There is no raw-HTTP video generation path, so a native Swift client cannot use
it for generation. `GET /v1/models` *does* tag video models with `type: "video"`
and capability tags (`t2v`, `i2v`, `r2v`, `motion-control`), which would make it
a usable discovery source if a gateway-backed provider is ever added behind a
Node-side proxy.

## Deferred: OpenAI-compatible `/v1/videos`

The Sora-shaped job API is the only OpenAI-flavoured video REST API, and is also
implemented by LiteLLM, New API and Azure Foundry. It is **not** wired up
because OpenAI has announced the shutdown of the Videos API and the `sora-2*`
models for **2026-09-24**. Documented here so the second provider is a drop-in:

| Step | Call |
|---|---|
| Submit | `POST {endpoint}/v1/videos` — `model`, `prompt`, `seconds`, `size`, optional `input_reference` (multipart file, or JSON `file_id` / `image_url`) |
| Poll | `GET {endpoint}/v1/videos/{id}` → job object with `progress` 0–100 |
| Download | `GET {endpoint}/v1/videos/{id}/content?variant=video\|thumbnail\|spritesheet` — URLs valid ~1 hour |

Job object: `{ id, object: "video", created_at, status, model, progress, seconds,
size }`, `status ∈ queued | in_progress | completed | failed`, plus `error` when
failed. Also available: `POST /v1/videos/extensions`, `POST /v1/videos/edits`,
`GET /v1/videos`, `DELETE /v1/videos/{id}`.

Adding it means: a `VideoProvider.openai` case, an `openAI*` column set on
`VideoGenProject` (the `google*` prefixes exist precisely so this needs no
migration), `startOpenAIVideo` / `pollOpenAIVideo` / `downloadOpenAIVideo` in
`VideoGenClient`, an `awaitOpenAICompletion` reusing the same loop, and an
`OpenAIModelsClient.videoModels` filter (`type == "video"`, or the `t2v`/`i2v`
tags, falling back to id heuristics). Note that `chatModels` currently filters
only on `!isImageModel`, so it would need `&& !isVideoModel` too.

## Job lifecycle and resumability

A Veo run costs money on submission and takes minutes, so the app never
re-submits work it has already paid for.

- `VideoGenerationService.start` persists `pendingJobID`, `pendingJobProvider`,
  `pendingJobModel`, `pendingJobPrompt` and `pendingJobStartedAt`, then saves.
- Cancelling, quitting, or a timeout **leaves those fields in place**. Only
  success and a hard provider failure clear them.
- The sidebar shows a spinner on any project with a pending job, and selecting
  one shows a banner offering **Resume** or **Discard**.
- Past 24 hours (`pendingJobIsStale`) only Discard is offered.
- Pressing Generate while a job is pending asks whether to resume it or abandon
  it and start a new one — it never silently drops a billed job.

For agents, `project_get` exposes `pendingJobId` / `pendingJobStartedAt`, and
there are `video_job_status` and `video_resume` tools for the case where
`video_generate` exceeded the caller's timeout.

## Storage

Clips land in `~/Library/Application Support/com.rxlab.film-workflow/videos/` as
`<uuid>.mp4`; `GeneratedVideo.videoFilePath` stores the relative path
(`videos/<uuid>.mp4`), resolved through `FileStorage.absoluteURL(for:)` like
every other asset. `VideoThumbnailer` extracts a poster frame at t≈0.5s into
`images/` and probes width/height/duration — both are best-effort and never fail
a render. Downloads are **moved** from the temp file rather than read into
memory. Deleting a project or a clip removes the mp4 and its thumbnail.

## MCP surface

- `list_projects` / `get_project` / `create_project` / `update_project` /
  `delete_project` / `duplicate_project` / `move_project` accept `type: "video"`.
- `update_project` fields: `name`, `prompt`, `negativePrompt`, `googleModel`,
  `googleAspectRatio`, `googleResolution`, `googleDuration`,
  `googlePersonGeneration`, `googleNumberOfVideos`, `googleGenerateAudio`,
  `useSeed`, `seed`. Unrecognised enum values are ignored, not raised.
- `duplicate_project` copies parameters and duplicates the frame/reference image
  files, but carries over neither the pending job nor the render history.
- `video_generate`, `video_job_status`, `video_resume` under
  `MCPGenerateHandlers`.

## Future

`docs/subscription-plan.md` plans an `AICapability` routing enum
(`chat`, `image`, `voice`, `caption`, `music`). A `case video` slots in
alongside them: `VideoGenerationService.generate(project:context:config:)` keeps
the same façade signature every other service uses, so routing would branch at
the top of `start` without touching the client or the views.
