import { z } from "zod";

const id = z.string().regex(/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/);
// Template files carry instructions, never a serialized document or file references.
const instruction = (max: number) => z.string().trim().max(max).refine(
  (text) => !/(?:file:\/\/|\/Users\/|\/Volumes\/|\/private\/|[A-Z]:\\)/.test(text),
  "Remove local file paths from the template.",
);
export const templateRequirement = z.strictObject({
  id, title: instruction(160).refine((text) => text.length > 0, "A title is required."),
  mediaType: z.enum(["video", "image", "audio"]),
  required: z.boolean(), instructions: instruction(4000),
});
export const templateDependency = z.strictObject({
  itemId: z.string().uuid(), purpose: instruction(1000), required: z.boolean(),
});
export const templateModifier = z.strictObject({
  modifierId: z.string().min(1).max(120),
  parameters: z.record(z.string(), z.union([z.number().finite(), instruction(120)])).default({}),
  durationSeconds: z.number().positive().max(10).optional(),
});
export const templateShot = z.strictObject({
  id, title: instruction(160).refine((text) => text.length > 0, "A title is required."),
  instructions: instruction(4000), durationSeconds: z.number().positive().max(600),
  footageRequirementId: id.optional(), marketplaceItemId: z.string().uuid().optional(),
  transition: templateModifier.optional(), effects: z.array(templateModifier).max(20).default([]),
});
export const projectTemplateDefinition = z.strictObject({
  version: z.literal(1), prompt: instruction(20000), videoStyle: instruction(4000),
  editingGuidance: instruction(8000),
  width: z.number().int().min(16).max(7680), height: z.number().int().min(16).max(7680),
  fps: z.number().int().min(1).max(120),
  shots: z.array(templateShot).max(100),
  footageRequirements: z.array(templateRequirement).max(100),
  marketplaceItems: z.array(templateDependency).max(100),
}).superRefine((value, ctx) => {
  const unique = (values: string[], path: string) => {
    if (new Set(values).size !== values.length) ctx.addIssue({ code: "custom", path: [path], message: "Identifiers must be unique." });
  };
  unique(value.shots.map((s) => s.id), "shots");
  unique(value.footageRequirements.map((s) => s.id), "footageRequirements");
  unique(value.marketplaceItems.map((s) => s.itemId), "marketplaceItems");
  for (const [index, shot] of value.shots.entries()) {
    if (shot.footageRequirementId && !value.footageRequirements.some((r) => r.id === shot.footageRequirementId)) {
      ctx.addIssue({ code: "custom", path: ["shots", index], message: "Shot references an unknown footage requirement." });
    }
    if (shot.marketplaceItemId && !value.marketplaceItems.some((r) => r.itemId === shot.marketplaceItemId)) {
      ctx.addIssue({ code: "custom", path: ["shots", index], message: "Shot references an unknown marketplace item." });
    }
  }
});
export type ProjectTemplateDefinition = z.infer<typeof projectTemplateDefinition>;
export type TemplateSummary = Pick<ProjectTemplateDefinition, "videoStyle" | "footageRequirements" | "marketplaceItems"> & { shotCount: number };
export function templateSummary(template: ProjectTemplateDefinition): TemplateSummary {
  return { videoStyle: template.videoStyle, footageRequirements: template.footageRequirements, marketplaceItems: template.marketplaceItems, shotCount: template.shots.length };
}
export function parseTemplate(text: string, publishing = false): ProjectTemplateDefinition {
  const value = projectTemplateDefinition.parse(JSON.parse(text));
  if (publishing && (!value.prompt || !value.videoStyle || !value.shots.length || value.shots.some((s) => !s.instructions) || value.footageRequirements.some((r) => !r.instructions))) {
    throw new Error("TEMPLATE_INVALID:Provide a prompt, style, shots, and instructions for every footage requirement.");
  }
  if (publishing && value.shots.some((s) => !s.footageRequirementId && !s.marketplaceItemId)) {
    throw new Error("TEMPLATE_INVALID:Every shot needs a footage requirement or marketplace source.");
  }
  return value;
}
