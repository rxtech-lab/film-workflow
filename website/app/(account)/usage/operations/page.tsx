import Link from "next/link";
import { BillingPagination } from "@/components/billing-pagination";
import { OperationList } from "@/components/usage-lists";
import { requirePageUser } from "@/lib/auth";
import { parseBillingHistoryPage, type BillingHistorySearchParams } from "@/lib/billing/history";
import { getUsageEventHistory } from "@/lib/billing/repository";

/** Every metered operation, paged. The /usage overview shows the most recent ten and links here. */
export default async function UsageOperationsPage({ searchParams }: { searchParams: Promise<BillingHistorySearchParams> }) {
  const [user, query] = await Promise.all([requirePageUser(), searchParams]);
  const operations = await getUsageEventHistory(user.id, parseBillingHistoryPage(query));

  return (
    <div className="mx-auto max-w-5xl">
      <Link href="/usage" className="text-sm text-muted hover:text-fg">← Usage</Link>
      <p className="mt-6 font-mono text-xs tracking-[.2em] text-accent uppercase">Metering</p>
      <h1 className="mt-2 text-4xl font-semibold">Metered operations</h1>
      <p className="mt-3 text-muted">Every provider call we charged you for. Pending rows have run but are still awaiting the provider&rsquo;s cost.</p>

      <section className="mt-8 rounded-2xl border border-line bg-surface p-6">
        {operations.total ? <small className="text-muted">{operations.total.toLocaleString("en-US")} total</small> : null}
        <div className="mt-4"><OperationList events={operations.events} /></div>
        <BillingPagination
          pathname="/usage/operations"
          currentPage={operations.currentPage}
          pageCount={operations.pageCount}
          searchParams={query}
          label="Metered operation pages"
        />
      </section>
    </div>
  );
}
