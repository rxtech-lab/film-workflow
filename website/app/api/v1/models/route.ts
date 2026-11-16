import { flowcyMedia } from "@/lib/ai/flowcy-media";
import { catalogForCapability } from "@/lib/ai/catalog";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";

export async function GET(request: Request) {
  try {
    await requireApiUser(request);
    const capability = new URL(request.url).searchParams.get("capability");
    const mediaCapabilities = new Set(["image", "video", "speech"]);
    if (capability && mediaCapabilities.has(capability)) return await flowcyMedia(request, `/api/v1/models?capability=${encodeURIComponent(capability)}`);
    const local = (await catalogForCapability(capability)).filter(model => !mediaCapabilities.has(model.capability));
    if (capability) return Response.json({ models: local }, { headers: { "Cache-Control": "private, no-store" } });
    const response = await flowcyMedia(request, "/api/v1/models");
    if (!response.ok) return response;
    const remote = await response.json() as { models: Array<{ capability: string }> };
    const models = [...local, ...remote.models.filter(model => mediaCapabilities.has(model.capability))];
    return Response.json({ models }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
