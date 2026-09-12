import Link from "next/link";
import { MarketplaceItemForm } from "@/components/marketplace-item-form";
import { listAllCategories } from "@/lib/marketplace/repository";

export default async function NewMarketplaceItemPage() {
  const categories = await listAllCategories();
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/admin/marketplace" className="text-sm text-muted hover:text-fg">← Marketplace</Link>
      <p className="mt-6 font-mono text-xs tracking-[.2em] text-accent uppercase">Admin</p>
      <h1 className="mt-2 text-4xl font-semibold">New item</h1>
      <p className="mt-3 text-muted">Pick a kind and the form shows what that kind needs. Files upload as soon as the draft is created.</p>
      <MarketplaceItemForm item={null} descriptorText="" categories={categories} />
    </div>
  );
}
