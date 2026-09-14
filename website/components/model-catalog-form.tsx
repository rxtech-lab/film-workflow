"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Trash2 } from "lucide-react";
import { ConfirmDialog } from "./confirm-dialog";
import { SearchableSelect, type SearchableOption } from "./searchable-select";
import { addAllDiscovered, addModel, removeAllForCapability, removeModel, setDefault, setEnabled, updateModel } from "@/lib/models/actions";
import { CAPABILITY_LABELS } from "@/lib/models/schema";
import type { CatalogModel } from "@/lib/ai/catalog";
import type { Capability } from "@/lib/db/schema";

export type CuratedModel = {
  id: string;
  modelId: string;
  capability: Capability;
  displayNameOverride: string | null;
  enabled: boolean;
  isDefault: boolean;
  sortOrder: number;
};

const primary = "rounded-full bg-accent px-4 py-2 text-sm font-medium text-black disabled:opacity-40";
const secondary = "rounded-full border border-line px-4 py-2 text-sm hover:bg-elevated disabled:opacity-40";
const danger = "rounded-full border border-red-500/40 px-4 py-2 text-sm text-red-400 hover:bg-red-500/10 disabled:opacity-40";
const field = "mt-1 w-full rounded-xl border border-line bg-elevated px-3 py-2 text-sm text-fg outline-none focus:border-accent";
const label = "block text-xs font-medium text-muted";

type Result = { ok: true } | { ok: false; error: string };
type Report = (result: Result, saved: string) => void;

function estimateLabel(model: CatalogModel) {
  if (!model.estimate) return "by tokens";
  return `≈ ${model.estimate.pointsPerUnit} cr/${model.estimate.unit.replace("audio_", "")}`;
}

/**
 * The offered catalog for one capability — the page picks which, from the URL.
 *
 * Each row saves on its own, so a half-finished edit in one row is never written
 * by saving another — the same contract the marketplace taxonomy form keeps.
 */
export function ModelCatalogForm({ capability, discovered, curated }: {
  capability: Capability;
  discovered: CatalogModel[];
  curated: CuratedModel[];
}) {
  const [notice, setNotice] = useState("");
  const [error, setError] = useState("");
  const router = useRouter();

  const report: Report = (result, saved) => {
    if (result.ok) { setError(""); setNotice(saved); router.refresh(); }
    else { setNotice(""); setError(result.error); }
  };

  return (
    <div className="mt-6 grid gap-6">
      <CapabilitySection capability={capability} discovered={discovered} curated={curated} onDone={report} />
      <div className="flex items-center gap-3 text-sm" aria-live="polite">
        {notice ? <span className="text-muted">{notice}</span> : null}
        {error ? <span className="text-red-400" role="alert">{error}</span> : null}
      </div>
    </div>
  );
}

function CapabilitySection({ capability, discovered, curated, onDone }: {
  capability: Capability;
  discovered: CatalogModel[];
  curated: CuratedModel[];
  onDone: Report;
}) {
  const [pending, startTransition] = useTransition();
  const [confirmingRemoveAll, setConfirmingRemoveAll] = useState(false);
  const byId = useMemo(() => new Map(discovered.map((model) => [model.id, model])), [discovered]);

  // A model already on the list must not be offered again.
  const options: SearchableOption[] = useMemo(() => {
    const taken = new Set(curated.map((row) => row.modelId));
    return discovered
      .filter((model) => !taken.has(model.id))
      .map((model) => ({ value: model.id, label: model.displayName, hint: model.id, detail: estimateLabel(model) }));
  }, [discovered, curated]);

  const rows = [...curated].sort((a, b) => a.sortOrder - b.sortOrder || a.modelId.localeCompare(b.modelId));

  return (
    <section className="rounded-2xl border border-line bg-surface p-6">
      <div className="flex flex-wrap items-baseline justify-between gap-3">
        <h2 className="text-lg font-semibold">{CAPABILITY_LABELS[capability]}</h2>
        <small className="text-muted">
          {rows.length} offered · {discovered.length} discovered
          {capability === "speech" || capability === "music"
            ? " · the route for this capability picks its own model, so curation here only changes what the catalog advertises"
            : null}
        </small>
      </div>

      <div className="mt-4 flex flex-wrap items-start gap-3">
        <div className="min-w-64 flex-1">
          <SearchableSelect
            options={options}
            disabled={pending || discovered.length === 0}
            placeholder={discovered.length === 0 ? "Nothing discovered for this capability" : `Search ${discovered.length} models…`}
            emptyLabel={curated.length && options.length === 0 ? "Everything discovered is already offered." : "No matches."}
            onSelect={(modelId) => startTransition(async () => {
              onDone(await addModel({ modelId, capability }), `${byId.get(modelId)?.displayName ?? modelId} added.`);
            })}
          />
        </div>
        <button
          type="button"
          className={secondary}
          disabled={pending || options.length === 0}
          onClick={() => startTransition(async () => {
            const result = await addAllDiscovered({ capability });
            onDone(result, result.ok ? `${result.added} model${result.added === 1 ? "" : "s"} added.` : "");
          })}
        >
          Add all {options.length ? `(${options.length})` : ""}
        </button>
        <button
          type="button"
          className={danger}
          disabled={pending || curated.length === 0}
          onClick={() => setConfirmingRemoveAll(true)}
        >
          Remove all {curated.length ? `(${curated.length})` : ""}
        </button>
      </div>

      {confirmingRemoveAll ? (
        <ConfirmDialog
          title={`Remove all ${CAPABILITY_LABELS[capability].toLowerCase()} models?`}
          body={<>This removes all {curated.length} from the offered list. {CAPABILITY_LABELS[capability]} pickers go empty and the API refuses every {capability} request until you add models back. Discovery is untouched, so you can re-add them with &ldquo;Add all&rdquo;.</>}
          confirmLabel={`Remove all ${curated.length}`}
          confirmPhrase={capability}
          pending={pending}
          onClose={() => setConfirmingRemoveAll(false)}
          onConfirm={() => startTransition(async () => {
            const result = await removeAllForCapability({ capability });
            setConfirmingRemoveAll(false);
            onDone(result, result.ok ? `${result.removed} model${result.removed === 1 ? "" : "s"} removed.` : "");
          })}
        />
      ) : null}

      {rows.length === 0
        ? <p className="mt-4 text-sm text-muted">Nothing offered for {CAPABILITY_LABELS[capability].toLowerCase()} — the picker will be empty and the API will refuse every request for it.</p>
        : <div className="mt-4 grid gap-3">{rows.map((row) => <ModelRow key={row.id} row={row} model={byId.get(row.modelId)} onDone={onDone} />)}</div>}
    </section>
  );
}

function ModelRow({ row, model, onDone }: { row: CuratedModel; model: CatalogModel | undefined; onDone: Report }) {
  const [name, setName] = useState(row.displayNameOverride ?? "");
  const [sortOrder, setSortOrder] = useState(row.sortOrder);
  const [confirmingRemove, setConfirmingRemove] = useState(false);
  const [pending, startTransition] = useTransition();
  const title = row.displayNameOverride?.trim() || model?.displayName || row.modelId;

  return (
    <>
    <form
      className={`grid gap-3 rounded-xl border border-line p-4 sm:grid-cols-[2fr_5rem_auto] sm:items-start ${row.enabled ? "" : "opacity-60"}`}
      onSubmit={(event) => {
        event.preventDefault();
        startTransition(async () => {
          onDone(await updateModel({ id: row.id, displayNameOverride: name, sortOrder }), `${title} saved.`);
        });
      }}
    >
      <label className={label}>Display name
        <input
          className={field}
          value={name}
          onChange={(event) => setName(event.target.value)}
          placeholder={model?.displayName ?? "Unavailable"}
          maxLength={80}
          disabled={pending}
        />
        <span className="mt-1 block font-mono text-xs text-muted">{row.modelId}</span>
        <span className="mt-1 block text-xs text-muted">
          {model
            ? <>{model.provider} · {estimateLabel(model)}</>
            : <span className="text-red-400">Unavailable from provider — it is not being offered; remove it.</span>}
        </span>
      </label>

      <label className={label}>Order
        <input
          className={field}
          type="number"
          min={0}
          max={999}
          step={1}
          value={sortOrder}
          onChange={(event) => setSortOrder(Math.max(0, Math.floor(Number(event.target.value) || 0)))}
          disabled={pending}
        />
      </label>

      <div className="flex flex-wrap items-center gap-3 sm:mt-5">
        <button type="submit" className={primary} disabled={pending}>{pending ? "Saving…" : "Save"}</button>
        <label className="flex items-center gap-2 text-xs text-muted">
          <input
            type="checkbox"
            checked={row.enabled}
            disabled={pending}
            onChange={(event) => startTransition(async () => {
              onDone(await setEnabled({ id: row.id, enabled: event.target.checked }), `${title} ${event.target.checked ? "enabled" : "disabled"}.`);
            })}
          />
          Enabled
        </label>
        <label className="flex items-center gap-2 text-xs text-muted" title="The model a picker preselects for this capability">
          <input
            type="radio"
            name={`default-${row.capability}`}
            checked={row.isDefault}
            disabled={pending || !row.enabled}
            onChange={() => startTransition(async () => {
              onDone(await setDefault({ id: row.id }), `${title} is now the default.`);
            })}
          />
          Default
        </label>
        <button
          type="button"
          className="text-muted hover:text-red-400 disabled:opacity-40"
          aria-label={`Remove ${title}`}
          disabled={pending}
          onClick={() => setConfirmingRemove(true)}
        >
          <Trash2 size={16} />
        </button>
      </div>
    </form>

      {confirmingRemove ? (
        <ConfirmDialog
          title={`Remove ${title}?`}
          body={<>It stops being offered to everyone and the API refuses it straight away. Nothing about the model itself changes, so you can add it back from the search field.</>}
          confirmLabel="Remove"
          pending={pending}
          onClose={() => setConfirmingRemove(false)}
          onConfirm={() => startTransition(async () => {
            const result = await removeModel({ id: row.id });
            setConfirmingRemove(false);
            onDone(result, `${title} removed.`);
          })}
        />
      ) : null}
    </>
  );
}
