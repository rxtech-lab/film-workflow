import Link from "next/link";
import { ArrowLeft, ArrowRight, Search } from "lucide-react";
import { MarketplaceCard } from "@/components/marketplace-card";
import { SfSymbol } from "@/components/sf-symbol";
import { requestLocale } from "@/lib/i18n/request";
import { localizedField } from "@/lib/i18n/translations";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listCategories, listKinds, listPublishedItems } from "@/lib/marketplace/repository";
import { CATALOG_VERSION, marketplaceKindDefaults } from "@/lib/marketplace/schema";
import { itemFacts, parseStorefrontQuery, previewMediaKind, priceLabel, storefrontHref } from "@/lib/marketplace/storefront";

export default async function MarketplacePage({ searchParams }: PageProps<"/marketplace">) {
  const query = parseStorefrontQuery(await searchParams);
  const locale = await requestLocale();
  const [kinds, categories, page] = await Promise.all([
    listKinds(CATALOG_VERSION),
    query.kind ? listCategories(query.kind, CATALOG_VERSION) : Promise.resolve([]),
    listPublishedItems({ ...query, catalog_version: CATALOG_VERSION }, locale),
  ]);
  const items = await Promise.all(page.items.map((item) => toWireItem(item, false, locale)));
  const shelves = kinds.filter((kind) => kind.count > 0);
  const totalPublished = shelves.reduce((sum, kind) => sum + kind.count, 0);
  const iconFor = new Map(kinds.map((kind) => [kind.kind, kind.icon]));

  return (
    <div>
      <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Marketplace</p>
      <h1 className="mt-2 text-4xl font-semibold tracking-[-0.03em] sm:text-5xl">Stock for your next cut.</h1>
      <p className="mt-3 max-w-2xl text-muted">
        Footage, music, sound effects, fonts, transitions and Remotion compositions — browse here, then buy and drop them onto your timeline from inside RxFilmStudio.
      </p>

      <form action="/marketplace" className="mt-8 flex max-w-xl items-center gap-2 rounded-full border border-line bg-surface px-4 py-2 focus-within:border-accent">
        <Search size={16} className="text-muted" aria-hidden="true" />
        {query.kind ? <input type="hidden" name="kind" value={query.kind} /> : null}
        {query.category ? <input type="hidden" name="category" value={query.category} /> : null}
        <input
          type="search"
          name="q"
          defaultValue={query.q ?? ""}
          placeholder="Search the marketplace"
          aria-label="Search the marketplace"
          maxLength={100}
          className="min-w-0 flex-1 bg-transparent text-sm outline-none placeholder:text-muted"
        />
        <button type="submit" className="rounded-full bg-fg px-3 py-1 text-xs font-medium text-ink hover:opacity-80">Search</button>
      </form>

      <nav aria-label="Kinds" className="mt-8 flex flex-wrap gap-2">
        <Chip href={storefrontHref({ q: query.q })} active={!query.kind} label="All" count={totalPublished} />
        {shelves.map((kind) => (
          <Chip
            key={kind.kind}
            href={storefrontHref({ kind: kind.kind, q: query.q })}
            active={query.kind === kind.kind}
            icon={kind.icon}
            label={localizedField(kind.translations, locale, "label", kind.label)}
            count={kind.count}
          />
        ))}
      </nav>

      {query.kind && categories.length > 0 ? (
        <nav aria-label="Categories" className="mt-3 flex flex-wrap gap-2">
          <Chip small href={storefrontHref({ kind: query.kind, q: query.q })} active={!query.category} label="Every category" />
          {categories.map((category) => (
            <Chip
              small
              key={category.id}
              href={storefrontHref({ kind: query.kind, category: category.slug, q: query.q })}
              active={query.category === category.slug}
              icon={category.icon}
              label={localizedField(category.translations, locale, "name", category.name)}
              count={category.count}
            />
          ))}
        </nav>
      ) : null}

      {items.length === 0 ? (
        <div className="mt-10 rounded-2xl border border-dashed border-line p-12 text-center text-muted">
          {query.q ? <>Nothing matches &ldquo;{query.q}&rdquo;. <Link href={storefrontHref({ kind: query.kind, category: query.category })} className="text-accent">Clear the search</Link></> : "Nothing on this shelf yet."}
        </div>
      ) : (
        <ul className="mt-10 grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          {items.map((item) => (
            <li key={item.id}>
              <MarketplaceCard
                href={`/marketplace/${item.id}`}
                imageUrl={item.preview_image_url}
                videoUrl={previewMediaKind(item.kind, item.preview_video_url) === "video" ? item.preview_video_url : null}
                symbol={iconFor.get(item.kind) ?? marketplaceKindDefaults[item.kind].icon}
                price={priceLabel(item.price_points)}
              >
                <div className="p-4">
                  <p className="font-mono text-[10px] tracking-[0.18em] text-muted uppercase">{item.category_name}</p>
                  <h2 className="mt-1 truncate font-medium group-hover:text-accent">{item.title}</h2>
                  {itemFacts(item.kind, item.metadata).length > 0 ? (
                    <p className="mt-1 text-xs text-muted tabular-nums">{itemFacts(item.kind, item.metadata).join(" · ")}</p>
                  ) : null}
                </div>
              </MarketplaceCard>
            </li>
          ))}
        </ul>
      )}

      {page.pageCount > 1 ? (
        <nav className="mt-10 flex items-center justify-between text-sm" aria-label="Marketplace pages">
          {page.currentPage > 1
            ? <Link href={storefrontHref({ ...query, page: page.currentPage - 1 })} className="inline-flex items-center gap-2 hover:text-accent"><ArrowLeft size={14} /> Previous</Link>
            : <span className="inline-flex items-center gap-2 text-muted opacity-40"><ArrowLeft size={14} /> Previous</span>}
          <span className="text-muted">Page {page.currentPage} of {page.pageCount} · {page.total.toLocaleString("en-US")} items</span>
          {page.currentPage < page.pageCount
            ? <Link href={storefrontHref({ ...query, page: page.currentPage + 1 })} className="inline-flex items-center gap-2 hover:text-accent">Next <ArrowRight size={14} /></Link>
            : <span className="inline-flex items-center gap-2 text-muted opacity-40">Next <ArrowRight size={14} /></span>}
        </nav>
      ) : null}
    </div>
  );
}

function Chip({ href, active, label, count, icon, small }: { href: string; active: boolean; label: string; count?: number; icon?: string; small?: boolean }) {
  return (
    <Link
      href={href}
      aria-current={active ? "page" : undefined}
      className={`inline-flex items-center gap-2 rounded-full border transition-colors ${small ? "px-3 py-1 text-xs" : "px-4 py-1.5 text-sm"} ${active ? "border-accent bg-accent/10 text-accent" : "border-line text-muted hover:border-fg/40 hover:text-fg"}`}
    >
      {icon ? <SfSymbol name={icon} size={small ? 12 : 14} color={active ? "#ffb020" : "#8b8f95"} /> : null}
      {label}
      {count !== undefined ? <span className="font-mono text-[10px] opacity-70">{count}</span> : null}
    </Link>
  );
}
