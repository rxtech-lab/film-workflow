"use client";

import { useState, useTransition } from "react";
import { updateCategory, updateKind } from "@/lib/marketplace/actions";
import { IconField } from "./marketplace-item-form";
import { marketplaceKindLabels, type MarketplaceCategory, type MarketplaceKind } from "@/lib/marketplace/schema";

export type KindView = { kind: MarketplaceKind; label: string; icon: string; sortOrder: number; count: number };
export type CategoryView = MarketplaceCategory & { count: number };

const primary = "rounded-full bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40";
const field = "mt-1 w-full rounded-xl border border-line bg-elevated px-3 py-2 text-sm text-fg outline-none focus:border-accent";
const label = "block text-xs font-medium text-muted";

/**
 * The sidebar the macOS app draws, edited in place: a row per kind and a row
 * per category. Saving one row leaves the others alone, so a half-finished
 * edit elsewhere on the page is never written.
 */
export function MarketplaceTaxonomyForm({ kinds, categories }: { kinds: KindView[]; categories: CategoryView[] }) {
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");

  function report(result: { ok: true } | { ok: false; error: string }, saved: string) {
    if (result.ok) { setError(""); setNotice(saved); } else { setNotice(""); setError(result.error); }
  }

  return (
    <div className="mt-8 grid gap-6">
      <section className="rounded-2xl border border-line bg-surface p-6">
        <h2 className="text-lg font-semibold">Kinds</h2>
        <p className="mt-1 text-sm text-muted">The top level of the app&rsquo;s sidebar. The order here is the order it shows, low first.</p>
        <div className="mt-4 grid gap-4">
          {kinds.map((entry) => <KindRow key={entry.kind} entry={entry} onDone={report} />)}
        </div>
      </section>

      <section className="rounded-2xl border border-line bg-surface p-6">
        <h2 className="text-lg font-semibold">Categories</h2>
        <p className="mt-1 text-sm text-muted">Shelves inside a kind. The slug is what published items filter on, so renaming one is safe.</p>
        {categories.length === 0 ? <p className="mt-4 text-sm text-muted">No categories yet. Add one from an item&rsquo;s form.</p> : null}
        <div className="mt-4 grid gap-4">
          {categories.map((category) => <CategoryRow key={category.id} category={category} onDone={report} />)}
        </div>
      </section>

      <div className="flex items-center gap-3 text-sm" aria-live="polite">
        {notice ? <span className="text-muted">{notice}</span> : null}
        {error ? <span className="text-red-400" role="alert">{error}</span> : null}
      </div>
    </div>
  );
}

type Report = (result: { ok: true } | { ok: false; error: string }, saved: string) => void;

function KindRow({ entry, onDone }: { entry: KindView; onDone: Report }) {
  const [text, setText] = useState(entry.label);
  const [icon, setIcon] = useState(entry.icon);
  const [sortOrder, setSortOrder] = useState(entry.sortOrder);
  const [pending, startTransition] = useTransition();

  return (
    <form
      className="grid gap-3 rounded-xl border border-line p-4 sm:grid-cols-[2fr_2fr_5rem_auto] sm:items-start"
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          onDone(await updateKind({ kind: entry.kind, label: text, icon, sortOrder }), `${marketplaceKindLabels[entry.kind]} saved.`);
        });
      }}
    >
      <label className={label}>Label<input className={field} value={text} onChange={(event) => setText(event.target.value)} maxLength={64} disabled={pending} /><span className="mt-1 block text-xs text-muted">{marketplaceKindLabels[entry.kind]} · {entry.count.toLocaleString("en-US")} published</span></label>
      <IconField value={icon} onChange={setIcon} disabled={pending} className="!mt-0" />
      <label className={label}>Order<input className={field} type="number" min={0} max={999} step={1} value={sortOrder} onChange={(event) => setSortOrder(Math.max(0, Math.floor(Number(event.target.value) || 0)))} disabled={pending} /></label>
      <button type="submit" className={`${primary} sm:mt-5`} disabled={pending || !text.trim()}>{pending ? "Saving…" : "Save"}</button>
    </form>
  );
}

function CategoryRow({ category, onDone }: { category: CategoryView; onDone: Report }) {
  const [name, setName] = useState(category.name);
  const [icon, setIcon] = useState(category.icon);
  const [pending, startTransition] = useTransition();

  return (
    <form
      className="grid gap-3 rounded-xl border border-line p-4 sm:grid-cols-[2fr_2fr_auto] sm:items-start"
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          onDone(await updateCategory({ id: category.id, name, icon }), `${name} saved.`);
        });
      }}
    >
      <label className={label}>Name<input className={field} value={name} onChange={(event) => setName(event.target.value)} maxLength={64} disabled={pending} /><span className="mt-1 block text-xs text-muted">{marketplaceKindLabels[category.kind]} · <span className="font-mono">{category.slug}</span> · {category.count.toLocaleString("en-US")} published</span></label>
      <IconField value={icon} onChange={setIcon} disabled={pending} className="!mt-0" />
      <button type="submit" className={`${primary} sm:mt-5`} disabled={pending || !name.trim()}>{pending ? "Saving…" : "Save"}</button>
    </form>
  );
}
