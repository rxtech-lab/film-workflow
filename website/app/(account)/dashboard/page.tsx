import Link from "next/link";
import { and, desc, eq, sql } from "drizzle-orm";
import { requirePageUser } from "@/lib/auth";
import { getBalance } from "@/lib/billing/subscription";
import { db } from "@/lib/db";
import { deviceSessions, usageEvents } from "@/lib/db/schema";

export default async function DashboardPage() {
  const user = await requirePageUser();
  const [balance, devices, [spent]] = await Promise.all([
    getBalance(user),
    db.select().from(deviceSessions).where(eq(deviceSessions.userId, user.id)).orderBy(desc(deviceSessions.lastSeenAt)).limit(8),
    // Purchase counts live in rx-subscription, but what a user actually burned
    // is this app's own metering, so it stays a local read.
    db.select({ points: sql<number>`coalesce(sum(${usageEvents.chargedPoints}), 0)` }).from(usageEvents).where(and(eq(usageEvents.userId, user.id), eq(usageEvents.status, "settled"))),
  ]);
  return <div className="mx-auto max-w-5xl"><p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Account overview</p><h1 className="mt-2 text-4xl font-semibold">Welcome back, {user.name}.</h1><div className="mt-8 grid gap-5 md:grid-cols-3"><Stat label="Available" value={balance.available} /><Stat label="Reserved" value={balance.amount - balance.available} /><Stat label="Spent all time" value={Number(spent?.points ?? 0)} /></div><section className="mt-10 rounded-2xl border border-line bg-surface p-6"><div className="flex items-center justify-between"><div><p className="text-sm text-muted">Signed-in devices</p><h2 className="mt-1 text-xl font-semibold">Desktop sessions</h2></div><Link className="rounded-full bg-accent px-4 py-2 text-sm font-medium text-black" href="/credits">Add credits</Link></div><div className="mt-5 grid gap-3">{devices.length ? devices.map((device) => <div key={device.id} className="flex justify-between rounded-xl bg-elevated px-4 py-3 text-sm"><span>{device.deviceName || device.platform}</span><span className="text-muted">{device.appVersion || "Unknown version"}</span></div>) : <p className="text-sm text-muted">No desktop app has checked in yet.</p>}</div></section></div>;
}

function Stat({ label, value }: { label: string; value: number }) {
  return <div className="rounded-2xl border border-line bg-surface p-6"><p className="text-sm text-muted">{label}</p><strong className="mt-2 block text-4xl tabular-nums">{value.toLocaleString("en-US")}</strong></div>;
}
