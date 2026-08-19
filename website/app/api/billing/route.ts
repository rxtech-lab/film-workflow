import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { getBillingSummary } from "@/lib/billing/summary";

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const summary = await getBillingSummary(user);
    return Response.json(summary, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
