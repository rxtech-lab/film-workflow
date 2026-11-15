import type { VeoRequest } from "./veo";

export function isOmniModel(model: string) {
  return model === "gemini-omni-1.2-flash" || model === "gemini-omni-1.1-flash";
}

/** URI delivery keeps generated video out of serverless JSON responses. */
export function omniRequestBody(model: string, input: VeoRequest) {
  const maxDuration = model === "gemini-omni-1.1-flash" || (input.firstFrame && input.lastFrame) ? 10 : 15;
  if (!Number.isInteger(input.durationSeconds) || input.durationSeconds < 3 || input.durationSeconds > maxDuration) throw new Error("VIDEO_OPTIONS_INVALID:Unsupported duration for this model and frames.");
  if ((input.referenceImages?.length ?? 0) > 6) throw new Error("VIDEO_OPTIONS_INVALID:At most six reference images are supported.");
  if (input.referenceImages?.length && (input.firstFrame || input.lastFrame)) throw new Error("VIDEO_OPTIONS_INVALID:Use frames or reference images in one generation.");
  if (input.lastFrame && !input.firstFrame) throw new Error("VIDEO_OPTIONS_INVALID:A last frame requires a first frame.");
  const content: Record<string, unknown>[] = [];
  let prompt = input.prompt.trim();
  if (!prompt) throw new Error("VIDEO_OPTIONS_INVALID:A prompt is required.");
  const image = (value: NonNullable<VeoRequest["firstFrame"]>) => ({ type: "image", data: value.base64, mime_type: value.mime_type });
  if (input.firstFrame) {
    content.push(image(input.firstFrame));
    if (input.lastFrame) content.push(image(input.lastFrame));
    prompt += input.lastFrame ? "\nAnimate from the first image to the second image as the ending frame." : "\nUse the image as the starting frame.";
  }
  for (const reference of input.referenceImages ?? []) content.push(image(reference));
  if (input.referenceImages?.length) prompt += "\nUse the images as visual references for consistent characters and objects.";
  if (input.negativePrompt?.trim()) prompt += `\nExclude the following: ${input.negativePrompt.trim()}`;
  content.push({ type: "text", text: prompt });
  return {
    model, input: content, background: true,
    response_format: { type: "video", delivery: "uri", aspect_ratio: input.aspectRatio, resolution: input.resolution ?? "720p", duration: `${input.durationSeconds}s` },
  };
}
