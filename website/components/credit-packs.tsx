"use client";

import { useState } from "react";

type CreditPack = { id: string; points: number; amountCents: number };

export function CreditPacks({ packs, enabled }: { packs: CreditPack[]; enabled: boolean }) {
  const [pendingPack, setPendingPack] = useState<string | null>(null);
  const [error, setError] = useState("");

  async function checkout(packId: string) {
    setPendingPack(packId);
    setError("");
    try {
      const response = await fetch("/api/billing/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          packId,
          source: new URLSearchParams(window.location.search).get("app") === "1" ? "desktop" : "web",
        }),
      });
      const body = await response.json() as { url?: string; error?: string };
      if (!response.ok || !body.url) throw new Error(body.error || "Checkout could not be created");
      window.location.assign(body.url);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : "Checkout could not be created");
      setPendingPack(null);
    }
  }

  return (
    <div>
      <div className="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
        {packs.map((pack) => (
          <article className="rounded-2xl border border-line bg-surface p-5" key={pack.id}>
            <span className="font-mono text-[10px] tracking-[.18em] text-muted uppercase">Prepaid credits</span>
            <strong className="mt-4 block text-3xl">{pack.points.toLocaleString("en-US")}</strong>
            <p className="text-sm text-muted">credits</p>
            <div className="mt-5 text-sm">${(pack.amountCents / 100).toFixed(2)} USD</div>
            <button className="mt-5 w-full rounded-full bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40" type="button" disabled={!enabled || pendingPack !== null} onClick={() => checkout(pack.id)}>
              {pendingPack === pack.id ? "Opening checkout…" : enabled ? "Buy credits" : "Purchases unavailable"}
            </button>
          </article>
        ))}
      </div>
      {error ? <p className="mt-4 text-sm text-red-400" role="alert">{error}</p> : null}
    </div>
  );
}
