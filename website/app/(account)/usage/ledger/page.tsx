import Link from "next/link";
import { BillingPagination } from "@/components/billing-pagination";
import { LedgerList } from "@/components/usage-lists";
import { requirePageUser } from "@/lib/auth";
import { parseBillingHistoryPage, type BillingHistorySearchParams } from "@/lib/billing/history";
import { getCreditHistory } from "@/lib/billing/subscription";

/** Every credit added, paged. The /usage overview shows the most recent ten and links here; what burned them is under Metered operations. */
export default async function UsageLedgerPage({ searchParams }: { searchParams: Promise<BillingHistorySearchParams> }) {
  const [user, query] = await Promise.all([requirePageUser(), searchParams]);
  const history = await getCreditHistory({ user, page: parseBillingHistoryPage(query) });

  return (
    <div className="mx-auto max-w-5xl">
      <Link href="/usage" className="text-sm text-muted hover:text-fg">← Usage</Link>
      <p className="mt-6 font-mono text-xs tracking-[.2em] text-accent uppercase">Billing</p>
      <h1 className="mt-2 text-4xl font-semibold">Credits added</h1>
      <p className="mt-3 text-muted">Every topup, plan grant and adjustment, as rx-subscription recorded it. What you spend is listed under Metered operations.</p>

      <section className="mt-8 rounded-2xl border border-line bg-surface p-6">
        {history.total ? <small className="text-muted">{history.total.toLocaleString("en-US")} total</small> : null}
        <div className="mt-4"><LedgerList entries={history.entries} /></div>
        <BillingPagination
          pathname="/usage/ledger"
          currentPage={history.page}
          pageCount={history.pageCount}
          searchParams={query}
          label="Credit history pages"
        />
      </section>
    </div>
  );
}
