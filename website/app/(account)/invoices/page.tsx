import Link from "next/link";
import { ArrowLeft, ArrowRight } from "lucide-react";
import { requirePageUser } from "@/lib/auth";
import { invoiceCursorHref, parseInvoiceCursor, type BillingHistorySearchParams } from "@/lib/billing/history";
import { getInvoices } from "@/lib/billing/subscription";

const invoiceDate = new Intl.DateTimeFormat("en-US", { dateStyle: "medium" });

export default async function InvoicesPage({ searchParams }: { searchParams: Promise<BillingHistorySearchParams> }) {
  const [user, query] = await Promise.all([requirePageUser(), searchParams]);
  const cursor = parseInvoiceCursor(query);
  // Receipts come from rx-subscription's Stripe-backed list, which is the only
  // place subscription renewals show up — they never produce a local top-up row.
  const { invoices, pagination } = await getInvoices({ user, ...cursor });
  // Stripe reports `has_more` for the direction being paged, and a cursor in the
  // query is the only signal that there is anything behind us to go back to.
  const previousHref = "after" in cursor || ("before" in cursor && pagination.hasMore)
    ? pagination.firstCursor && invoiceCursorHref({ before: pagination.firstCursor })
    : null;
  const nextHref = "before" in cursor || pagination.hasMore
    ? pagination.lastCursor && invoiceCursorHref({ after: pagination.lastCursor })
    : null;
  return <div className="mx-auto max-w-5xl"><p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Billing</p><h1 className="mt-2 text-4xl font-semibold">Invoices</h1><section className="mt-8 rounded-2xl border border-line bg-surface p-6"><div className="divide-y divide-line">{invoices.length ? invoices.map((invoice) => <div className="flex items-center justify-between gap-4 py-4" key={invoice.id}><span><strong className="block">{invoice.description || invoice.number || "Payment"}</strong><small className="text-muted">{invoiceDate.format(new Date(invoice.createdAt))} · ${(invoice.amountCents / 100).toFixed(2)} {invoice.currency.toUpperCase()} · {invoice.status}</small></span><span className="flex gap-3 text-sm text-accent">{invoice.hostedInvoiceUrl ? <Link href={invoice.hostedInvoiceUrl} target="_blank">Invoice</Link> : null}{invoice.invoicePdfUrl ? <Link href={invoice.invoicePdfUrl} target="_blank">PDF</Link> : null}</span></div>) : <p className="text-sm text-muted">No invoices yet.</p>}</div>{previousHref || nextHref ? <nav className="mt-6 flex items-center justify-between text-sm" aria-label="Invoice pages">{previousHref ? <Link href={previousHref}><ArrowLeft size={14} /> Newer</Link> : <span className="inline-flex items-center gap-2 text-muted opacity-40"><ArrowLeft size={14} /> Newer</span>}{nextHref ? <Link href={nextHref}>Older <ArrowRight size={14} /></Link> : <span className="inline-flex items-center gap-2 text-muted opacity-40">Older <ArrowRight size={14} /></span>}</nav> : null}</section></div>;
}
