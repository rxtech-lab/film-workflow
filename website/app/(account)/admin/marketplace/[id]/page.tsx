import Link from "next/link";
import { notFound } from "next/navigation";
import { MarketplaceItemForm, type AdminItemView } from "@/components/marketplace-item-form";
import { previewURL } from "@/lib/marketplace/presenter";
import { getItem, listAllCategories } from "@/lib/marketplace/repository";
import { getObjectBytes, marketplaceUploadLimits } from "@/lib/storage/s3";

export default async function EditMarketplaceItemPage({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: Promise<{ error?: string }> }) {
  const [{ id }, query] = await Promise.all([params, searchParams]);
  const item = await getItem(id);
  if (!item) notFound();
  // The kinds whose content is text edited in the form rather than an uploaded file.
  const isInlineContent = ["effect", "transition", "project_template"].includes(item.kind);
  const [previewImageUrl, previewVideoUrl, descriptorText, categories] = await Promise.all([
    previewURL(item.previewImageKey).catch(() => null),
    previewURL(item.previewVideoKey).catch(() => null),
    isInlineContent && item.contentKey
      ? getObjectBytes(item.contentKey, marketplaceUploadLimits.content).then(({ bytes }) => bytes.toString("utf8")).catch(() => "")
      : Promise.resolve(""),
    listAllCategories(),
  ]);
  const view: AdminItemView = {
    id: item.id,
    kind: item.kind,
    categoryId: item.categoryId,
    title: item.title,
    description: item.description,
    pricePoints: item.pricePoints,
    metadata: item.metadata,
    translations: item.translations,
    status: item.status,
    previewImageUrl,
    previewVideoUrl,
    contentFilename: item.contentFilename,
    contentSizeBytes: item.contentSizeBytes,
    updatedAt: item.updatedAt.toISOString(),
  };
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/admin/marketplace" className="text-sm text-muted hover:text-fg">← Marketplace</Link>
      <p className="mt-6 font-mono text-xs tracking-[.2em] text-accent uppercase">Admin · {item.status}</p>
      <h1 className="mt-2 text-4xl font-semibold">{item.title}</h1>
      {/* `error` carries an upload failure over from the create flow, which redirects here. */}
      <MarketplaceItemForm item={view} descriptorText={descriptorText} categories={categories} initialError={query.error ?? ""} />
    </div>
  );
}
