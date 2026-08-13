import { gateway } from "@ai-sdk/gateway";
import { and, eq } from "drizzle-orm";
import { nanoUsdFromUsd, reconcileReviewedUsage } from "@/lib/billing/repository";
import { db } from "@/lib/db";
import { usageEvents } from "@/lib/db/schema";

export async function GET(request: Request) {
  const secret = process.env.CRON_SECRET?.trim();
  if (!secret || request.headers.get("authorization") !== `Bearer ${secret}`) return Response.json({ error: "Unauthorized" }, { status: 401 });
  const needsReview = await db.select().from(usageEvents).where(and(
    eq(usageEvents.status, "needs_review"),
    eq(usageEvents.provider, "vercel-ai-gateway"),
  )).limit(100);
  let reconciled = 0;
  const failures: Array<{ id: string; code: string }> = [];
  for (const event of needsReview) {
    if (!event.externalId) {
      failures.push({ id: event.id, code: "MISSING_GENERATION_ID" });
      continue;
    }
    try {
      const generation = await gateway.getGenerationInfo({ id: event.externalId });
      await reconcileReviewedUsage({
        eventId: event.id,
        provider: generation.providerName || "vercel-ai-gateway",
        model: generation.model || event.model || "unknown",
        costNanoUsd: nanoUsdFromUsd(generation.totalCost),
      });
      reconciled += 1;
    } catch (cause) {
      failures.push({
        id: event.id,
        code: cause instanceof Error ? cause.message.slice(0, 120) : "UNKNOWN_ERROR",
      });
    }
  }
  return Response.json({ scanned: needsReview.length, reconciled, failures });
}
