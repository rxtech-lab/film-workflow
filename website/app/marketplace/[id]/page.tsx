import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { cache } from "react";
import { ArrowLeft, Download } from "lucide-react";
import { z } from "zod";
import { requestLocale } from "@/lib/i18n/request";
import { toWireItem } from "@/lib/marketplace/presenter";
import { getItem } from "@/lib/marketplace/repository";
import { marketplaceKindDefaults, resolutionLabel } from "@/lib/marketplace/schema";
import { durationLabel, previewMediaKind, priceLabel, sizeLabel, storefrontHref } from "@/lib/marketplace/storefront";
import { getLatestRelease } from "../../lib/release";

/** A published item in the visitor's language, or nothing. Drafts are never shown here, admin or not. */
const loadItem = cache(async (id: string) => {
  if (!z.string().uuid().safeParse(id).success) return null;
  const item = await getItem(id);
  if (!item || item.status !== "published") return null;
  return toWireItem(item, false, await requestLocale());
});

export async function generateMetadata({ params }: PageProps<"/marketplace/[id]">): Promise<Metadata> {
  const item = await loadItem((await params).id);
  if (!item) return { title: "Marketplace — RxFilmStudio" };
  const description = item.description.slice(0, 200) || `${item.category_name} on the RxFilmStudio marketplace.`;
  return {
    title: `${item.title} — RxFilmStudio Marketplace`,
    description,
    alternates: { canonical: `/marketplace/${item.id}` },
    openGraph: { title: item.title, description, images: item.preview_image_url ? [item.preview_image_url] : undefined },
  };
}

export default async function MarketplaceItemPage({ params }: PageProps<"/marketplace/[id]">) {
  const [item, release] = await Promise.all([loadItem((await params).id), getLatestRelease()]);
  if (!item) notFound();

  const media = previewMediaKind(item.kind, item.preview_video_url);
  const facts: [string, string | undefined][] = [
    ["Kind", marketplaceKindDefaults[item.kind].label],
    ["Category", item.category_name],
    ["Resolution", item.kind === "footage" && item.metadata.width && item.metadata.height ? `${resolutionLabel(item.metadata)} · ${item.metadata.width}×${item.metadata.height}` : undefined],
    ["Length", durationLabel(item.metadata.durationSeconds)],
    ["Font family", item.metadata.fontFamily],
    ["File", item.content_filename ? [item.content_filename, sizeLabel(item.content_size_bytes)].filter(Boolean).join(" · ") : undefined],
    ["Published", item.published_at ? new Date(item.published_at).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric" }) : undefined],
  ];

  return (
    <article>
      <Link href={storefrontHref({ kind: item.kind })} className="inline-flex items-center gap-2 text-sm text-muted hover:text-accent">
        <ArrowLeft size={14} /> {marketplaceKindDefaults[item.kind].label}
      </Link>

      <div className="mt-6 grid gap-10 lg:grid-cols-[minmax(0,3fr)_minmax(0,2fr)]">
        <div className="overflow-hidden rounded-2xl border border-line bg-elevated">
          {media === "video" ? (
            <video src={item.preview_video_url ?? undefined} poster={item.preview_image_url ?? undefined} controls playsInline loop className="aspect-video w-full bg-black object-contain" />
          ) : item.preview_image_url ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img src={item.preview_image_url} alt={item.title} className="aspect-video w-full object-cover" />
          ) : (
            <div className="flex aspect-video items-center justify-center font-mono text-xs tracking-[0.18em] text-muted uppercase">No preview</div>
          )}
          {media === "audio" ? (
            <audio src={item.preview_video_url ?? undefined} controls className="w-full border-t border-line" />
          ) : null}
        </div>

        <div>
          <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">{item.category_name}</p>
          <h1 className="mt-2 text-3xl font-semibold tracking-[-0.03em] sm:text-4xl">{item.title}</h1>
          <p className="mt-4 text-2xl font-medium tabular-nums">{priceLabel(item.price_points)}</p>

          <a href={release.dmgUrl} className="mt-6 inline-flex items-center gap-2 rounded-full bg-accent px-6 py-3 text-sm font-medium text-ink transition-transform hover:scale-[1.03]">
            <Download size={16} /> Get RxFilmStudio to use it
          </a>
          <p className="mt-3 text-xs text-muted">
            Open the Marketplace inside the app to {item.price_points === 0 ? "install it for free" : "buy it with your credits"} and drop it onto your timeline.
          </p>

          {item.description ? <p className="mt-8 whitespace-pre-line text-muted">{item.description}</p> : null}

          <dl className="mt-8 divide-y divide-line rounded-2xl border border-line bg-surface text-sm">
            {facts.filter((fact): fact is [string, string] => Boolean(fact[1])).map(([term, value]) => (
              <div key={term} className="flex justify-between gap-4 px-4 py-3">
                <dt className="text-muted">{term}</dt>
                <dd className="truncate text-right tabular-nums">{value}</dd>
              </div>
            ))}
          </dl>

          {item.metadata.tags?.length ? (
            <ul className="mt-6 flex flex-wrap gap-2" aria-label="Tags">
              {item.metadata.tags.map((tag) => (
                <li key={tag}>
                  <Link href={storefrontHref({ q: tag })} className="rounded-full border border-line px-3 py-1 text-xs text-muted hover:border-accent hover:text-accent">#{tag}</Link>
                </li>
              ))}
            </ul>
          ) : null}
        </div>
      </div>
    </article>
  );
}
