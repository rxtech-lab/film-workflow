import { catalogForCapability } from "@/lib/ai/catalog";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";

export async function GET(request: Request) {
  try {
    await requireApiUser(request);
    const models = await catalogForCapability(new URL(request.url).searchParams.get("capability"));
    return Response.json({ models }, { headers: { "Cache-Control": "private, max-age=0", "CDN-Cache-Control": "s-maxage=900" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
