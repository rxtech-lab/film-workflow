import Link from "next/link";
import { MarketplaceTaxonomyForm } from "@/components/marketplace-taxonomy-form";
import { listCategoriesForAdmin, listKinds } from "@/lib/marketplace/repository";

/** Labels and SF Symbols for the app's marketplace sidebar; the app reads them off the wire. */
export default async function MarketplaceTaxonomyPage() {
  const [kinds, categories] = await Promise.all([listKinds(), listCategoriesForAdmin()]);
  return (
    <div className="mx-auto max-w-3xl">
      <Link href="/admin/marketplace" className="text-sm text-muted hover:text-fg">← Marketplace</Link>
      <p className="mt-6 font-mono text-xs tracking-[.2em] text-accent uppercase">Admin</p>
      <h1 className="mt-2 text-4xl font-semibold">Sidebar</h1>
      <p className="mt-3 text-muted">What the app shows down the side of the marketplace window. Changes reach the app the next time it loads the catalog — no release needed.</p>
      <MarketplaceTaxonomyForm kinds={kinds} categories={categories} />
    </div>
  );
}
