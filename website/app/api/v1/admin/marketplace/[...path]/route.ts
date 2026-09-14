import { createHash } from "node:crypto";
import { z } from "zod";
import { requireAdminUser } from "@/lib/auth/bearer";
import { requestLocale } from "@/lib/i18n/request";
import { marketplaceRouteError } from "@/lib/marketplace/http";
import { toWireItem } from "@/lib/marketplace/presenter";
import { listAllCategories, listAllItemsForAdmin, requireItem, ownedItemIds, type MarketplaceItem } from "@/lib/marketplace/repository";
import * as authoring from "@/lib/marketplace/authoring";
import { marketplaceFormSchema } from "@/lib/marketplace/form-schema";
import { assetRoles } from "@/lib/marketplace/schema";
import { getObjectBytes, objectDownloadURL } from "@/lib/storage/s3";

const headers = { "Cache-Control": "private, no-store", Vary: "Accept-Language" };
const json = (body: unknown, status = 200) => Response.json(body, { status, headers });
type Context = { params: Promise<{ path: string[] }> };

/**
 * One item for an editor rather than a reader: `item` keeps the text as it was
 * typed — `toWireItem` is left at the default locale on purpose — and
 * `translations` carries the other languages beside it, which is what the form
 * edits. Only the form's own labels follow `Accept-Language` here.
 */
async function adminItem(item: MarketplaceItem, owned = false) {
  const structured = ["project_template", "effect", "transition"].includes(item.kind);
  const contentText = structured && item.contentKey ? (await getObjectBytes(item.contentKey)).bytes.toString("utf8") : null;
  return { item: await toWireItem(item, owned), translations: item.translations, category_id: item.categoryId, status: item.status, updated_at: item.updatedAt.toISOString(), content_text: contentText,
    content_revision: item.contentKey ? createHash("sha256").update(item.contentKey).digest("hex") : null,
    content_download_url: item.contentKey ? await objectDownloadURL(item.contentKey) : null };
}
async function handle(request: Request, context: Context) {
  try {
    const user = await requireAdminUser(request);
    const { path } = await context.params;
    const [resource, id, operation] = path;
    if (id && resource === "items") z.uuid().parse(id);
    if (path.length > 3) return json({ error: "Not found." }, 404);
    if (request.method === "GET") {
      if (resource === "capabilities") return json({ can_author: true, user_id: user.id });
      // The app renders its authoring form from this, so both forms stay the same shape.
      if (resource === "form-schema") return json(marketplaceFormSchema(await requestLocale(request)));
      if (resource === "categories") return json({ categories: await listAllCategories() });
      if (resource === "items" && !id) {
        const query = z.object({
          page: z.coerce.number().int().min(1).default(1),
          scope: z.enum(["all", "mine"]).default("all"),
          status: z.enum(["draft", "published"]).optional(),
          q: z.string().trim().max(200).optional(),
        }).parse(Object.fromEntries(new URL(request.url).searchParams));
        const result = await listAllItemsForAdmin(query.page, {
          createdBy: query.scope === "mine" ? user.id : undefined,
          status: query.status,
          query: query.q,
        });
        const owned = await ownedItemIds(user.id, result.items.map((item) => item.id));
        return json({ items: await Promise.all(result.items.map((item) => adminItem(item, owned.has(item.id)))), page: result.currentPage, page_count: result.pageCount, total: result.total });
      }
      if (resource === "items" && id && !operation) return json(await adminItem(await requireItem(id), (await ownedItemIds(user.id, [id])).has(id)));
    }
    const body = request.method === "DELETE" ? {} : await request.json();
    let result: authoring.ActionResult | undefined;
    if (request.method === "POST") {
      if (resource === "categories" && !id) result = await authoring.createCategory(user, body);
      if (resource === "items" && !id) result = await authoring.createItem(user, body);
      if (resource === "uploads" && !id) result = await authoring.createUploadUrl(user, body);
      if (resource === "uploads" && id === "finalize") result = await authoring.finalizeUpload(user, body);
      if (resource === "items" && id && operation === "publish") result = await authoring.publishItem(user, id, z.object({ published: z.boolean() }).parse(body).published);
    }
    if (request.method === "PATCH" && resource === "items" && id && !operation) result = await authoring.updateItem(user, id, body);
    // Renaming or re-iconing a category. The slug is what items filter on, so
    // it is not part of the patch and stays put.
    if (request.method === "PATCH" && resource === "categories" && id && !operation) result = await authoring.updateCategory(user, { ...body, id });
    if (request.method === "PUT" && resource === "items" && id && operation === "content") result = await authoring.saveContent(user, id, z.object({ text: z.string().max(1_000_000) }).parse(body).text);
    if (request.method === "DELETE" && resource === "items" && id && operation) result = await authoring.removeAsset(user, id, z.enum(assetRoles).parse(operation));
    if (request.method === "DELETE" && resource === "items" && id && !operation) result = await authoring.deleteItem(user, id);
    if (!result) return json({ error: "Not found." }, 404);
    return json(result, result.ok ? 200 : 400);
  } catch (cause) {
    if (cause instanceof z.ZodError || cause instanceof SyntaxError) return json({ error: "Invalid request.", details: cause.message }, 400);
    return marketplaceRouteError(cause);
  }
}
export const GET = handle;
export const POST = handle;
export const PATCH = handle;
export const PUT = handle;
export const DELETE = handle;
