import { z } from "zod";
import { capabilityEnum, type Capability } from "@/lib/db/schema";

export const capabilities = capabilityEnum.enumValues;

export const CAPABILITY_LABELS: Record<Capability, string> = {
  chat: "Chat",
  image: "Image",
  speech: "Speech",
  music: "Music",
  transcription: "Transcription",
  translation: "Translation",
  video: "Video",
};

const capability = z.enum(capabilities);

/** Blank means "use the provider's name", which is what the null column stores. */
const displayNameOverride = z.string().trim().max(80).nullish().transform((value) => value || null);

const sortOrder = z.number().int().min(0).max(999);

export const addModelInput = z.object({
  modelId: z.string().trim().min(1).max(200),
  capability,
});

export const updateModelInput = z.object({
  id: z.string().min(1),
  displayNameOverride,
  sortOrder,
});

export const setEnabledInput = z.object({ id: z.string().min(1), enabled: z.boolean() });
export const identifiedModel = z.object({ id: z.string().min(1) });
/** No capability means "every capability". */
export const addAllInput = z.object({ capability: capability.nullish() });
/** Removing every row is always scoped to one capability — there is no "clear the whole catalog". */
export const removeAllInput = z.object({ capability });

export type AddModelInput = z.infer<typeof addModelInput>;
export type UpdateModelInput = z.infer<typeof updateModelInput>;
