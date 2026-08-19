import { and, desc, eq, sql } from "drizzle-orm";
import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { getLedger } from "@/lib/billing/subscription";
import { db } from "@/lib/db";
import { usageEvents } from "@/lib/db/schema";

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const url = new URL(request.url);
    const requestedPage = Number(url.searchParams.get("page") ?? "1");
    const [ledger, usage, grouped] = await Promise.all([
      getLedger({ user, page: Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1 }),
      db.select().from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).orderBy(desc(usageEvents.createdAt)).limit(20),
      db.select({ capability: usageEvents.capability, points: sql<number>`coalesce(sum(${usageEvents.chargedPoints}), 0)` }).from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).groupBy(usageEvents.capability),
    ]);
    // The ledger moved to rx-subscription, but the desktop app reads the field
    // names the local table used, so they are kept on the wire.
    const entries = ledger.entries.map((entry) => ({
      id: entry.id,
      kind: entry.kind,
      pointsDelta: entry.delta,
      balanceAfter: entry.balanceAfter,
      description: entry.description,
      referenceId: entry.referenceId,
      createdAt: entry.createdAt,
    }));
    return Response.json({
      entries,
      total: ledger.total,
      currentPage: ledger.page,
      pageCount: ledger.pageCount,
      usage,
      grouped,
    }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
