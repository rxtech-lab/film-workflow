"use client";

import { useState, useTransition } from "react";
import { deleteCategory, updateCategory, updateKind } from "@/lib/marketplace/actions";
import { IconField } from "./marketplace-icon-field";
import { ConfirmDialog } from "./confirm-dialog";
import { localeNames, TRANSLATABLE_LOCALES, type Translations } from "@/lib/i18n/translations";
import type { Locale } from "@/lib/i18n/locale";
import { DEFAULT_CATEGORY_ICON, marketplaceKindLabels, type MarketplaceCategory, type MarketplaceKind } from "@/lib/marketplace/schema";

export type KindView = { kind: MarketplaceKind; label: string; icon: string; sortOrder: number; count: number; translations: Translations };
export type CategoryView = MarketplaceCategory & { count: number; totalCount: number };

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
        <p className="mt-1 text-sm text-muted">Edit a category&rsquo;s name and symbol, then save the row. Its slug stays the same. To delete a category, move its items to another category first.</p>
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

/**
 * The same field again in every language the app ships besides the one the row
 * itself is written in. Blank means "no translation": the app falls back to
 * the text above rather than showing an empty sidebar row.
 */
function TranslationFields({ title, field: fieldName, translations, onChange, disabled, className = "" }: {
  title: string;
  field: string;
  translations: Translations;
  onChange: (next: Translations) => void;
  disabled: boolean;
  className?: string;
}) {
  return (
    <>
      {TRANSLATABLE_LOCALES.map((locale: Locale) => (
        <label key={locale} className={`${label} ${className}`}>{title} · {localeNames[locale]}
          <input
            className={field}
            value={translations[locale]?.[fieldName] ?? ""}
            onChange={(event) => onChange({ ...translations, [locale]: { ...translations[locale], [fieldName]: event.target.value } })}
            maxLength={64}
            disabled={disabled}
          />
        </label>
      ))}
    </>
  );
}

function KindRow({ entry, onDone }: { entry: KindView; onDone: Report }) {
  const [text, setText] = useState(entry.label);
  const [icon, setIcon] = useState(entry.icon);
  const [sortOrder, setSortOrder] = useState(entry.sortOrder);
  const [translations, setTranslations] = useState<Translations>(entry.translations ?? {});
  const [pending, startTransition] = useTransition();

  return (
    <form
      className="grid gap-3 rounded-xl border border-line p-4 sm:grid-cols-[minmax(0,2fr)_minmax(0,2fr)_5rem_auto] sm:items-start"
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          const result = await updateKind({ kind: entry.kind, label: text, icon, sortOrder, translations });
          if (result.ok) { setText(text.trim()); setIcon(icon.trim() || DEFAULT_CATEGORY_ICON); }
          onDone(result, `${marketplaceKindLabels[entry.kind]} saved.`);
        });
      }}
    >
      <label className={label}>Label<input className={field} value={text} onChange={(event) => setText(event.target.value)} maxLength={64} disabled={pending} /><span className="mt-1 block text-xs text-muted">{marketplaceKindLabels[entry.kind]} · {entry.count.toLocaleString("en-US")} published</span></label>
      <IconField value={icon} onChange={setIcon} disabled={pending} className="!mt-0" />
      <label className={label}>Order<input className={field} type="number" min={0} max={999} step={1} value={sortOrder} onChange={(event) => setSortOrder(Math.max(0, Math.floor(Number(event.target.value) || 0)))} disabled={pending} /></label>
      <button type="submit" className={`${primary} sm:mt-5`} disabled={pending || !text.trim()}>{pending ? "Saving…" : "Save"}</button>
      <TranslationFields title="Label" field="label" translations={translations} onChange={setTranslations} disabled={pending} className="sm:col-span-4" />
    </form>
  );
}

function CategoryRow({ category, onDone }: { category: CategoryView; onDone: Report }) {
  const [name, setName] = useState(category.name);
  const [icon, setIcon] = useState(category.icon);
  const [translations, setTranslations] = useState<Translations>(category.translations ?? {});
  const [pending, startTransition] = useTransition();
  const [confirming, setConfirming] = useState(false);
  const hasItems = category.totalCount > 0;

  return (
    <>
    <form
      className="grid gap-3 rounded-xl border border-line p-4 sm:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] sm:items-start"
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          const result = await updateCategory({ id: category.id, name, icon, translations });
          if (result.ok) { setName(result.category.name); setIcon(result.category.icon); setTranslations(result.category.translations); }
          onDone(result, `${name.trim()} saved.`);
        });
      }}
    >
      <label className={label}>Name<input className={field} value={name} onChange={(event) => setName(event.target.value)} maxLength={64} disabled={pending} /><span className="mt-1 block text-xs text-muted">{marketplaceKindLabels[category.kind]} · <span className="font-mono">{category.slug}</span> · {category.totalCount.toLocaleString("en-US")} {category.totalCount === 1 ? "item" : "items"} ({category.count.toLocaleString("en-US")} published)</span></label>
      <IconField value={icon} onChange={setIcon} disabled={pending} className="!mt-0" />
      <TranslationFields title="Name" field="name" translations={translations} onChange={setTranslations} disabled={pending} className="sm:col-span-2" />
      <div className="flex flex-wrap items-center gap-2 sm:col-span-2">
        {hasItems ? <p id={`category-${category.id}-delete-hint`} className="mr-auto text-xs text-muted">Move all items before deleting.</p> : null}
        <button type="button" className="ml-auto rounded-full border border-red-400/30 px-4 py-2 text-sm text-red-400 hover:bg-red-400/10 disabled:cursor-not-allowed disabled:opacity-40"
          disabled={pending || hasItems} aria-describedby={hasItems ? `category-${category.id}-delete-hint` : undefined}
          onClick={() => setConfirming(true)}>Delete</button>
        <button type="submit" className={primary} disabled={pending || !name.trim()}>{pending ? "Saving…" : "Save"}</button>
      </div>
    </form>
    {confirming ? <ConfirmDialog
      title={`Delete “${category.name}”?`}
      body="This permanently removes the empty category from the marketplace. It cannot be recovered."
      confirmLabel="Delete category"
      pending={pending}
      onClose={() => setConfirming(false)}
      onConfirm={() => startTransition(async () => {
        const result = await deleteCategory({ id: category.id });
        setConfirming(false);
        onDone(result, `${category.name} deleted.`);
      })}
    /> : null}
    </>
  );
}
