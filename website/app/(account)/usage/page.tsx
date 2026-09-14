import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { and, eq, sql } from "drizzle-orm";
import { LedgerList, OperationList } from "@/components/usage-lists";
import { requirePageUser } from "@/lib/auth";
import { getUsageEventHistory, USAGE_EVENT_SUMMARY_SIZE } from "@/lib/billing/repository";
import { getCreditHistory } from "@/lib/billing/subscription";
import { db } from "@/lib/db";
import { usageEvents } from "@/lib/db/schema";

const showAll = "inline-flex items-center gap-2 rounded-full border border-line px-4 py-2 text-sm hover:bg-elevated";

/** An overview: the credits each capability has burned, and the most recent rows of each history. Paging lives on the detail pages. */
export default async function UsagePage() {
  const user = await requirePageUser();
  const [history, grouped, operations] = await Promise.all([
    // Credits added are rx-subscription's record; what burned them is this
    // app's, and the operations list below already spells those out.
    getCreditHistory({ user, page: 1, pageSize: USAGE_EVENT_SUMMARY_SIZE }),
    db.select({ capability: usageEvents.capability, points: sql<number>`coalesce(sum(${usageEvents.chargedPoints}), 0)`.mapWith(Number) }).from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))).groupBy(usageEvents.capability),
    getUsageEventHistory(user.id, 1, USAGE_EVENT_SUMMARY_SIZE),
  ]);

  return (
    <div className="mx-auto max-w-5xl">
      <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Metering</p>
      <h1 className="mt-2 text-4xl font-semibold">Usage</h1>

      <div className="mt-8 grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        {grouped.map((group) => (
          <div key={group.capability} className="rounded-2xl border border-line bg-surface p-4">
            <p className="capitalize text-sm text-muted">{group.capability}</p>
            <strong className="mt-1 block text-2xl">{Number(group.points).toLocaleString("en-US")}</strong>
          </div>
        ))}
      </div>

      <section className="mt-8 rounded-2xl border border-line bg-surface p-6">
        <div className="flex items-baseline justify-between gap-4">
          <h2 className="text-xl font-semibold">Metered operations</h2>
          {operations.total ? <small className="text-muted">Latest {Math.min(operations.total, USAGE_EVENT_SUMMARY_SIZE)} of {operations.total.toLocaleString("en-US")}</small> : null}
        </div>
        <div className="mt-4"><OperationList events={operations.events} /></div>
        {operations.total > USAGE_EVENT_SUMMARY_SIZE
          ? <Link href="/usage/operations" className={`${showAll} mt-6`}>Show all <ArrowRight size={14} /></Link>
          : null}
      </section>

      <section className="mt-8 rounded-2xl border border-line bg-surface p-6">
        <div className="flex items-baseline justify-between gap-4">
          <h2 className="text-xl font-semibold">Credits added</h2>
          {history.total ? <small className="text-muted">Latest {Math.min(history.total, USAGE_EVENT_SUMMARY_SIZE)} of {history.total.toLocaleString("en-US")}</small> : null}
        </div>
        <div className="mt-4"><LedgerList entries={history.entries} /></div>
        {history.total > USAGE_EVENT_SUMMARY_SIZE
          ? <Link href="/usage/ledger" className={`${showAll} mt-6`}>Show all <ArrowRight size={14} /></Link>
          : null}
      </section>
    </div>
  );
}
