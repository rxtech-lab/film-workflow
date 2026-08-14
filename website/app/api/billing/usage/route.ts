import { and, desc, eq, sql } from "drizzle-orm";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { getPointHistory } from "@/lib/billing/repository";
import { db } from "@/lib/db";
import { usageEvents } from "@/lib/db/schema";

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const url = new URL(request.url);
    const requestedPage = Number(url.searchParams.get("page") ?? "1");
    const [history, usage, grouped] = await Promise.all([
      getPointHistory(user.id, Number.isSafeInteger(requestedPage) ? requestedPage : 1),
      db.select().from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).orderBy(desc(usageEvents.createdAt)).limit(20),
      db.select({ capability: usageEvents.capability, points: sql<number>`coalesce(sum(${usageEvents.chargedPoints}), 0)` }).from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).groupBy(usageEvents.capability),
    ]);
    return Response.json({ ...history, usage, grouped }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
