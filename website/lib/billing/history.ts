export type BillingHistorySearchParams = Record<string, string | string[] | undefined>;

function firstSearchParam(value: string | string[] | undefined) {
  return Array.isArray(value) ? value[0] : value;
}

export function parseBillingHistoryPage(searchParams: BillingHistorySearchParams) {
  const requestedPage = Number.parseInt(firstSearchParam(searchParams.page) ?? "1", 10);
  return Number.isSafeInteger(requestedPage) && requestedPage > 0 ? requestedPage : 1;
}

export function billingHistoryHref(pathname: "/usage" | "/invoices", page: number) {
  return `${pathname}?page=${Math.max(1, page)}`;
}
