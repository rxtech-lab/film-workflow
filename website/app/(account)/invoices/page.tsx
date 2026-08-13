import Link from "next/link";
import { BillingPagination } from "@/components/billing-pagination";
import { requirePageUser } from "@/lib/auth";
import { parseBillingHistoryPage, type BillingHistorySearchParams } from "@/lib/billing/history";
import { getInvoiceHistory } from "@/lib/billing/repository";

export default async function InvoicesPage({ searchParams }: { searchParams: Promise<BillingHistorySearchParams> }) {
  const user = await requirePageUser();
  const history = await getInvoiceHistory(user.id, parseBillingHistoryPage(await searchParams));
  return <div className="mx-auto max-w-5xl"><p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Billing</p><h1 className="mt-2 text-4xl font-semibold">Invoices</h1><section className="mt-8 rounded-2xl border border-line bg-surface p-6"><div className="divide-y divide-line">{history.invoices.length ? history.invoices.map((invoice) => <div className="flex items-center justify-between py-4" key={invoice.id}><span><strong className="block">{invoice.points.toLocaleString("en-US")} credits</strong><small className="text-muted">${(invoice.amountCents / 100).toFixed(2)} {invoice.currency.toUpperCase()}</small></span><span className="flex gap-3 text-sm text-accent">{invoice.hostedInvoiceUrl ? <Link href={invoice.hostedInvoiceUrl} target="_blank">Invoice</Link> : null}{invoice.invoicePdfUrl ? <Link href={invoice.invoicePdfUrl} target="_blank">PDF</Link> : null}</span></div>) : <p className="text-sm text-muted">No paid top-ups yet.</p>}</div><BillingPagination pathname="/invoices" currentPage={history.currentPage} pageCount={history.pageCount} /></section></div>;
}
