import Link from "next/link";
import { CreditPacks } from "@/components/credit-packs";
import { requirePageUser } from "@/lib/auth";
import { getBillingSummary } from "@/lib/billing/summary";

export default async function CreditsPage({ searchParams }: { searchParams: Promise<{ checkout?: string; app?: string }> }) {
  const user = await requirePageUser();
  const [summary, query] = await Promise.all([getBillingSummary(user), searchParams]);
  // The balance is read from rx-subscription on every render with no caching,
  // so returning from Checkout shows the topup as soon as its webhook settles
  // there — this page needs no reconciliation of its own.
  return <div className="mx-auto max-w-5xl"><p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Billing</p><div className="mt-2 flex flex-wrap items-end justify-between gap-4"><div><h1 className="text-4xl font-semibold">Credits</h1><p className="mt-2 text-muted">Prepaid provider-cost credits. 1,000 credits represent one US dollar of provider usage.</p></div><div className="rounded-2xl border border-line bg-surface px-6 py-4 text-right"><span className="text-xs text-muted">Available</span><strong className="block text-3xl tabular-nums">{summary.availablePoints.toLocaleString("en-US")}</strong>{summary.reservedPoints ? <small className="text-muted">{summary.reservedPoints.toLocaleString("en-US")} reserved</small> : null}</div></div>{query.checkout ? <div className="mt-6 rounded-xl border border-accent/30 bg-accent/10 p-4 text-sm">{query.checkout === "success" ? "Payment received. Credits appear as soon as the payment is confirmed." : "Checkout was cancelled. No credits were added."}</div> : null}{query.app === "1" ? <a className="mt-5 inline-flex rounded-full bg-accent px-4 py-2 text-sm font-medium text-black" href="filmstudio://credits/refresh">Return to RxFilm Studio</a> : null}<section className="mt-10"><div className="mb-4"><h2 className="text-xl font-semibold">Top up</h2><p className="text-sm text-muted">Pack prices include the RxFilm service margin.</p></div><CreditPacks packs={summary.packs} enabled={summary.enabled} /></section><section className="mt-10 rounded-2xl border border-line bg-surface p-6"><h2 className="text-xl font-semibold">Recent activity</h2><p className="mt-2 text-sm text-muted">Every metered generation and credit purchase is listed under usage.</p><Link className="mt-4 inline-block text-sm text-accent" href="/usage?page=1">View full usage</Link></section></div>;
}
