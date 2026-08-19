export type BillingHistorySearchParams = Record<string, string | string[] | undefined>;

/** A page can host several paginated sections, so each one owns a query param and pages independently. */
export const LEDGER_PAGE_PARAM = "page";
export const OPERATIONS_PAGE_PARAM = "ops";

function firstSearchParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

export function parseBillingHistoryPage(searchParams: BillingHistorySearchParams, param: string = LEDGER_PAGE_PARAM) {
  const requestedPage = Number.parseInt(firstSearchParam(searchParams[param]) ?? "1", 10);
  return Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1;
}

/**
 * Invoices page backwards/forwards through Stripe by invoice id rather than by
 * page number, so it carries a cursor instead of an offset. The two are
 * mutually exclusive — rx-subscription 400s when both are sent.
 */
export function parseInvoiceCursor(searchParams: BillingHistorySearchParams) {
  const after = firstSearchParam(searchParams.after);
  if (after) return { after };
  const before = firstSearchParam(searchParams.before);
  return before ? { before } : {};
}

export function invoiceCursorHref(cursor: { after?: string; before?: string }) {
  return `/invoices?${new URLSearchParams(cursor)}`;
}

export function billingHistoryHref(
  pathname: "/usage",
  page: number,
  options?: { param?: string; searchParams?: BillingHistorySearchParams },
) {
  // Carry the rest of the query through so paging one section keeps the others where they are.
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(options?.searchParams ?? {})) {
    const first = firstSearchParam(value);
    if (first !== undefined) query.set(key, first);
  }
  query.set(options?.param ?? LEDGER_PAGE_PARAM, String(Math.max(1, page)));
  return `${pathname}?${query}`;
}
