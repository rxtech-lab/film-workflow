import "server-only";

import type { MarketplaceItem } from "@/lib/marketplace/repository";
import { objectDownloadURL, publicObjectURL } from "@/lib/storage/s3";

/** Preview media are public on the R2 domain; without one, fall back to a presigned read. */
export async function previewURL(key: string | null) {
  if (!key) return null;
  return publicObjectURL(key) ?? await objectDownloadURL(key);
}

/**
 * The item as the macOS client sees it: snake_case, preview URLs resolved, and
 * no storage key for the content file — that only comes out of the download
 * route after the purchase check.
 */
export async function toWireItem(item: MarketplaceItem, owned: boolean) {
  const [previewImageUrl, previewVideoUrl] = await Promise.all([previewURL(item.previewImageKey), previewURL(item.previewVideoKey)]);
  return {
    id: item.id,
    kind: item.kind,
    category: item.category,
    category_name: item.categoryName,
    title: item.title,
    description: item.description,
    price_points: item.pricePoints,
    preview_image_url: previewImageUrl,
    preview_video_url: previewVideoUrl,
    content_filename: item.contentFilename,
    content_size_bytes: item.contentSizeBytes,
    content_type: item.contentType,
    metadata: item.metadata,
    owned,
    published_at: item.publishedAt?.toISOString() ?? null,
  };
}

export type WireItem = Awaited<ReturnType<typeof toWireItem>>;
