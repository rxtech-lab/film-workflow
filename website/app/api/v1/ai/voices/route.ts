import { flowcyMedia } from "@/lib/ai/flowcy-media";
import { aiRouteError } from "@/lib/ai/http";
export const maxDuration = 300;
export async function GET(request: Request) {
  try { return await flowcyMedia(request, "/api/v1/ai/voices" + new URL(request.url).search); }
  catch (cause) { return aiRouteError(cause); }
}
