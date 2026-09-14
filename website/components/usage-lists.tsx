import { LocalTime } from "@/components/local-time";
import type { LedgerEntry } from "@/lib/billing/subscription";
import type { usageEvents } from "@/lib/db/schema";

export type UsageEventRow = typeof usageEvents.$inferSelect;

/**
 * The two history lists on /usage, shared with the detail pages behind "Show
 * all" so an overview row and a full-history row cannot drift apart.
 */
export function OperationList({ events }: { events: UsageEventRow[] }) {
  if (events.length === 0) return <p className="py-3 text-sm text-muted">No metered operations yet.</p>;
  return (
    <div className="divide-y divide-line">
      {events.map((entry) => (
        <div className="grid grid-cols-[1fr_auto] gap-4 py-3 text-sm" key={entry.id}>
          <span>
            <strong className="block font-medium">{entry.feature}</strong>
            <small className="text-muted">{entry.provider} · {entry.model || "default"} · {entry.unitCount ?? "—"} {entry.unitKind ?? "units"}</small>
            <small className="mt-0.5 block text-muted"><LocalTime value={entry.createdAt.toISOString()} /></small>
          </span>
          {entry.status === "settled"
            ? <b>-{entry.chargedPoints.toLocaleString("en-US")}</b>
            : <span className="text-muted" title="Awaiting provider cost reconciliation">Pending</span>}
        </div>
      ))}
    </div>
  );
}

export function LedgerList({ entries }: { entries: LedgerEntry[] }) {
  if (entries.length === 0) return <p className="py-3 text-sm text-muted">No credits added yet.</p>;
  return (
    <div className="divide-y divide-line">
      {entries.map((entry) => (
        <div className="grid grid-cols-[1fr_auto] gap-4 py-3 text-sm" key={entry.id}>
          <span>
            <strong className="block font-medium">{entry.description}</strong>
            <small className="text-muted"><LocalTime value={entry.createdAt} /></small>
          </span>
          <b>{entry.delta > 0 ? "+" : ""}{entry.delta.toLocaleString("en-US")}</b>
        </div>
      ))}
    </div>
  );
}
