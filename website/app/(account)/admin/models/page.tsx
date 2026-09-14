import Link from "next/link";
import { ModelCatalogForm } from "@/components/model-catalog-form";
import { discoveredCatalog } from "@/lib/ai/catalog";
import { listCatalogModels } from "@/lib/models/repository";
import { CAPABILITY_LABELS, capabilities } from "@/lib/models/schema";
import type { Capability } from "@/lib/db/schema";

type SearchParams = Record<string, string | string[] | undefined>;

/**
 * The capability being edited lives in the URL, so a reload, a back button or a
 * shared link all land on the same tab — and each request renders one section
 * instead of all seven, which matters when the gateway alone offers 245 chat
 * models.
 */
function selectedCapability(searchParams: SearchParams): Capability {
  const raw = searchParams.capability;
  const value = Array.isArray(raw) ? raw[0] : raw;
  return capabilities.find((entry) => entry === value) ?? capabilities[0];
}

/** What every user's model picker offers. Discovery finds the candidates; this page decides which ones we serve. */
export default async function AdminModelsPage({ searchParams }: { searchParams: Promise<SearchParams> }) {
  const [query, discovered, curated] = await Promise.all([searchParams, discoveredCatalog(), listCatalogModels()]);
  const capability = selectedCapability(query);

  return (
    <div className="mx-auto max-w-4xl">
      <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Admin</p>
      <h1 className="mt-2 text-4xl font-semibold">Model catalog</h1>
      <p className="mt-3 max-w-2xl text-muted">
        The models offered to everyone, per capability. Anything not on a list here is hidden from the picker and refused by the API.
        Removing a model takes effect immediately on the server, but a running app can keep showing it for up to an hour while its cached catalog expires.
      </p>

      <nav className="mt-8 flex flex-wrap gap-2" aria-label="Capability">
        {capabilities.map((entry) => {
          const offered = curated.filter((row) => row.capability === entry && row.enabled).length;
          const isSelected = entry === capability;
          return (
            <Link
              key={entry}
              href={`/admin/models?capability=${entry}`}
              aria-current={isSelected ? "page" : undefined}
              className={`rounded-full border px-4 py-2 text-sm transition-colors ${
                isSelected
                  ? "border-accent/40 bg-accent/10 text-accent"
                  : "border-line text-muted hover:bg-elevated hover:text-fg"
              }`}
            >
              {CAPABILITY_LABELS[entry]} <span className="text-xs opacity-70">{offered}</span>
            </Link>
          );
        })}
      </nav>

      <ModelCatalogForm
        capability={capability}
        discovered={discovered.filter((model) => model.capability === capability)}
        curated={curated
          .filter((row) => row.capability === capability)
          .map(({ id, modelId, capability: rowCapability, displayNameOverride, enabled, isDefault, sortOrder }) =>
            ({ id, modelId, capability: rowCapability, displayNameOverride, enabled, isDefault, sortOrder }))}
      />
    </div>
  );
}
