import { afterEach, describe, expect, it, vi } from "vitest";

vi.mock("server-only", () => ({}));

type Entry = { id: string; kind: string; delta: number; createdAt: string };

/** Stands in for rx-subscription's paged `/balances/ledger`. */
function serveLedger(entries: Entry[]) {
  const calls: URL[] = [];
  const fetchMock = vi.fn(async (input: string | URL) => {
    const url = new URL(input.toString());
    calls.push(url);
    const page = Number(url.searchParams.get("page") ?? "1");
    const pageSize = Number(url.searchParams.get("pageSize") ?? "20");
    const pageCount = Math.max(1, Math.ceil(entries.length / pageSize));
    return {
      ok: true,
      json: async () => ({
        entries: entries.slice((page - 1) * pageSize, page * pageSize),
        total: entries.length,
        page,
        pageSize,
        pageCount,
      }),
    } as Response;
  });
  vi.stubGlobal("fetch", fetchMock);
  return calls;
}

async function creditHistory(entries: Entry[], page: number, pageSize?: number) {
  process.env.RX_SUBSCRIPTION_URL = "https://subscription.test";
  process.env.RX_SUBSCRIPTION_API_KEY = "test-key";
  const calls = serveLedger(entries);
  const { getCreditHistory } = await import("@/lib/billing/subscription");
  const result = await getCreditHistory({ user: { id: "user-1" } as never, page, pageSize });
  return { result, calls };
}

const topup = (id: string): Entry => ({ id, kind: "topup", delta: 1000, createdAt: "2026-09-14T08:28:00Z" });
const spend = (id: string): Entry => ({ id, kind: "usage", delta: -167, createdAt: "2026-09-14T10:48:00Z" });

describe("credit history", () => {
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.resetModules();
  });

  it("leaves metered spends to the operations list", async () => {
    const { result } = await creditHistory(
      [spend("a"), spend("b"), topup("c"), { id: "d", kind: "overage", delta: -12, createdAt: "2026-09-13T00:00:00Z" }],
      1,
    );
    expect(result.entries.map((entry) => entry.id)).toEqual(["c"]);
    expect(result.total).toBe(1);
    expect(result.pageCount).toBe(1);
  });

  it("keeps every other way credits move, newest first", async () => {
    const kinds = ["topup", "plan_grant", "refund", "adjustment", "expiry", "dispute", "dispute_reversal"];
    const { result } = await creditHistory(
      kinds.map((kind, index) => ({ id: kind, kind, delta: index, createdAt: "2026-09-14T00:00:00Z" })),
      1,
    );
    expect(result.entries.map((entry) => entry.kind)).toEqual(kinds);
  });

  it("pages the credits that survive the filter, not the raw ledger", async () => {
    // 60 movements, every other one a spend: 30 credits over three pages of 10.
    const entries = Array.from({ length: 60 }, (_, index) =>
      index % 2 === 0 ? topup(`credit-${index}`) : spend(`spend-${index}`));
    const { result, calls } = await creditHistory(entries, 2, 10);
    expect(result.total).toBe(30);
    expect(result.pageCount).toBe(3);
    expect(result.page).toBe(2);
    expect(result.entries).toHaveLength(10);
    expect(result.entries[0]?.id).toBe("credit-20");
    // Upstream is read at its own page size, not the caller's.
    expect(calls.every((url) => url.searchParams.get("pageSize") === "100")).toBe(true);
  });

  it("clamps a page past the end instead of returning nothing", async () => {
    const { result } = await creditHistory([topup("a"), spend("b")], 9, 10);
    expect(result.page).toBe(1);
    expect(result.entries.map((entry) => entry.id)).toEqual(["a"]);
  });

  it("asks for one upstream page when one holds everything", async () => {
    const { calls } = await creditHistory([topup("a")], 1);
    expect(calls).toHaveLength(1);
    expect(calls[0]?.searchParams.get("page")).toBe("1");
  });
});
