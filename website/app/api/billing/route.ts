import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { getBillingSummary } from "@/lib/billing/repository";

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const summary = await getBillingSummary(user.id);
    return Response.json(summary, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
