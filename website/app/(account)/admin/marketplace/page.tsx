import Link from "next/link";
import { ArrowLeft, ArrowRight, Plus } from "lucide-react";
import { deleteItemAction, togglePublishAction } from "@/lib/marketplace/actions";
import { listAllItemsForAdmin } from "@/lib/marketplace/repository";
import { marketplaceKindLabels } from "@/lib/marketplace/schema";

function pageHref(page: number) {
  return `/admin/marketplace?page=${Math.max(1, page)}`;
}

export default async function AdminMarketplacePage({ searchParams }: { searchParams: Promise<{ page?: string }> }) {
  const query = await searchParams;
  const requested = Number.parseInt(query.page ?? "1", 10);
  const { items, total, currentPage, pageCount } = await listAllItemsForAdmin(Number.isSafeInteger(requested) && requested > 0 ? requested : 1);
  return (
    <div className="mx-auto max-w-5xl">
      <div className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="font-mono text-xs tracking-[.2em] text-accent uppercase">Admin</p>
          <h1 className="mt-2 text-4xl font-semibold">Marketplace</h1>
          <p className="mt-3 max-w-2xl text-muted">Footage, prompts, sounds, fonts and effects the app can install. Drafts stay invisible until published.</p>
        </div>
        <Link href="/admin/marketplace/new" className="inline-flex items-center gap-2 rounded-full bg-accent px-4 py-2 text-sm font-medium text-black"><Plus size={14} /> New item</Link>
      </div>
      <div className="mt-8 overflow-hidden rounded-2xl border border-line bg-surface">
        <table className="w-full text-left text-sm">
          <thead className="bg-elevated text-muted"><tr><th className="p-4">Item</th><th className="p-4">Kind</th><th className="p-4">Category</th><th className="p-4">Price</th><th className="p-4">Status</th><th className="p-4"><span className="sr-only">Actions</span></th></tr></thead>
          <tbody className="divide-y divide-line">
            {items.length === 0 ? <tr><td className="p-4 text-muted" colSpan={6}>No items yet.</td></tr> : null}
            {items.map((item) => (
              <tr key={item.id}>
                <td className="p-4"><Link href={`/admin/marketplace/${item.id}`} className="block font-medium hover:text-accent">{item.title}</Link><small className="text-xs text-muted">{item.contentFilename ?? "No content file"} · updated {item.updatedAt.toLocaleDateString("en-US")}</small></td>
                <td className="p-4">{marketplaceKindLabels[item.kind]}</td>
                <td className="p-4">{item.categoryName}</td>
                <td className="p-4 tabular-nums">{item.pricePoints === 0 ? "Free" : `${item.pricePoints.toLocaleString("en-US")} credits`}</td>
                <td className="p-4"><span className={`rounded-full px-2 py-0.5 text-xs ${item.status === "published" ? "bg-accent/10 text-accent" : "bg-elevated text-muted"}`}>{item.status}</span></td>
                <td className="p-4">
                  <div className="flex justify-end gap-2">
                    <form action={togglePublishAction}><input type="hidden" name="id" value={item.id} /><input type="hidden" name="published" value={item.status === "published" ? "false" : "true"} /><button type="submit" className="rounded-full border border-line px-3 py-1 text-xs hover:bg-elevated" disabled={item.status !== "published" && !item.contentKey} title={item.status !== "published" && !item.contentKey ? "Upload the content file first" : undefined}>{item.status === "published" ? "Unpublish" : "Publish"}</button></form>
                    <form action={deleteItemAction}><input type="hidden" name="id" value={item.id} /><button type="submit" className="rounded-full border border-line px-3 py-1 text-xs text-red-400 hover:bg-elevated">Delete</button></form>
                  </div>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {pageCount > 1 ? (
        <nav className="mt-6 flex items-center justify-between text-sm" aria-label="Item pages">
          {currentPage > 1 ? <Link href={pageHref(currentPage - 1)} className="inline-flex items-center gap-2"><ArrowLeft size={14} /> Previous</Link> : <span className="inline-flex items-center gap-2 text-muted opacity-40"><ArrowLeft size={14} /> Previous</span>}
          <span>Page {currentPage} of {pageCount} · {total.toLocaleString("en-US")} items</span>
          {currentPage < pageCount ? <Link href={pageHref(currentPage + 1)} className="inline-flex items-center gap-2">Next <ArrowRight size={14} /></Link> : <span className="inline-flex items-center gap-2 text-muted opacity-40">Next <ArrowRight size={14} /></span>}
        </nav>
      ) : null}
    </div>
  );
}
