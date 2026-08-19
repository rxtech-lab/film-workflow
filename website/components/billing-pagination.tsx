import Link from "next/link";
import { ArrowLeft, ArrowRight } from "lucide-react";
import { billingHistoryHref, type BillingHistorySearchParams } from "@/lib/billing/history";

export function BillingPagination({
  pathname,
  currentPage,
  pageCount,
  param,
  searchParams,
  label = "History pages",
}: {
  pathname: "/usage";
  currentPage: number;
  pageCount: number;
  param?: string;
  searchParams?: BillingHistorySearchParams;
  label?: string;
}) {
  if (pageCount <= 1) return null;
  const href = (page: number) => billingHistoryHref(pathname, page, { param, searchParams });
  return (
    <nav className="mt-6 flex items-center justify-between text-sm" aria-label={label}>
      {currentPage > 1
        ? <Link href={href(currentPage - 1)}><ArrowLeft size={14} /> Previous</Link>
        : <span className="inline-flex items-center gap-2 text-muted opacity-40"><ArrowLeft size={14} /> Previous</span>}
      <span>Page {currentPage} of {pageCount}</span>
      {currentPage < pageCount
        ? <Link href={href(currentPage + 1)}>Next <ArrowRight size={14} /></Link>
        : <span className="inline-flex items-center gap-2 text-muted opacity-40">Next <ArrowRight size={14} /></span>}
    </nav>
  );
}
