import { and, desc, eq, sql } from "drizzle-orm";
import { BillingPagination } from "@/components/billing-pagination";
import { requirePageUser } from "@/lib/auth";
import { parseBillingHistoryPage, type BillingHistorySearchParams } from "@/lib/billing/history";
import { getPointHistory } from "@/lib/billing/repository";
import { db } from "@/lib/db";
import { usageEvents } from "@/lib/db/schema";

export default async function UsagePage({ searchParams }: { searchParams: Promise<BillingHistorySearchParams> }) {
  const user = await requirePageUser();
  const [history, grouped, recent] = await Promise.all([
    getPointHistory(user.id, parseBillingHistoryPage(await searchParams)),
    db.select({ capability: usageEvents.capability, points: sql<number>`coalesce(sum(${usageEvents.chargedPoints}), 0)` }).from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).groupBy(usageEvents.capability),
    db.select().from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).orderBy(desc(usageEvents.createdAt)).limit(20),
  ]);
  return <div className="mx-auto max-w-5xl"><p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Metering</p><h1 className="mt-2 text-4xl font-semibold">Usage</h1><div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">{grouped.map((group) => <div key={group.capability} className="rounded-2xl border border-line bg-surface p-4"><p className="capitalize text-sm text-muted">{group.capability}</p><strong className="mt-1 block text-2xl">{Number(group.points).toLocaleString("en-US")}</strong></div>)}</div><section className="mt-8 rounded-2xl border border-line bg-surface p-6"><h2 className="text-xl font-semibold">Metered operations</h2><div className="mt-4 divide-y divide-line">{recent.map((entry) => <div className="grid grid-cols-[1fr_auto] gap-4 py-3 text-sm" key={entry.id}><span><strong className="block font-medium">{entry.feature}</strong><small className="text-muted">{entry.provider} · {entry.model || "default"} · {entry.unitCount ?? "—"} {entry.unitKind ?? "units"}</small></span><b>-{entry.chargedPoints.toLocaleString("en-US")}</b></div>)}</div></section><section className="mt-8 rounded-2xl border border-line bg-surface p-6"><h2 className="text-xl font-semibold">Credit ledger</h2><div className="mt-4 divide-y divide-line">{history.entries.map((entry) => <div className="flex justify-between py-3 text-sm" key={entry.id}><span>{entry.description}</span><b>{entry.pointsDelta > 0 ? "+" : ""}{entry.pointsDelta.toLocaleString("en-US")}</b></div>)}</div><BillingPagination pathname="/usage" currentPage={history.currentPage} pageCount={history.pageCount} /></section></div>;
}
