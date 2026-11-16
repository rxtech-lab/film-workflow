import "server-only";
import { createHash, createHmac } from "node:crypto";
import { requireApiUser } from "@/lib/auth/bearer";

/** Native bearer identity is verified again by Flowcy; provider keys stay in Flowcy. */
export async function flowcyMedia(request: Request, path: string) {
  const user = await requireApiUser(request);
  const authorization = request.headers.get("authorization");
  if (!authorization?.toLowerCase().startsWith("bearer "))
    return Response.json({ code: "unauthorized", error: "Native account sign-in required." }, { status: 401 });
  const base = new URL(process.env.FLOWCY_MEDIA_URL ?? (process.env.NODE_ENV === "production" ? "https://www.flowcy.dev" : "http://localhost:3001"));
  if (base.protocol !== "https:" && !(base.protocol === "http:" && ["localhost", "127.0.0.1"].includes(base.hostname))) throw new Error("FLOWCY_MEDIA_URL_REQUIRES_HTTPS");
  const headers = new Headers({ authorization, accept: "application/json", "content-type": "application/json" });
  for (const name of ["accept-language", "idempotency-key", "x-client-platform", "x-client-version"]) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  const body = request.method === "GET" ? undefined : await request.text();
  if (body && Buffer.byteLength(body) > 1_000_000) return Response.json({ error: "Use presigned S3 uploads for media inputs." }, { status: 413 });
  const secret = process.env.FILM_MEDIA_SHARED_SECRET;
  if (!secret) throw new Error("FILM_MEDIA_SHARED_SECRET_NOT_CONFIGURED");
  const timestamp = String(Date.now());
  const target = new URL(path, base);
  const canonical = [timestamp, request.method, target.pathname, user.id, request.headers.get("idempotency-key") ?? "", createHash("sha256").update(body ?? "").digest("hex")].join("\n");
  headers.set("x-flowcy-timestamp", timestamp);
  headers.set("x-flowcy-signature", createHmac("sha256", secret).update(canonical).digest("hex"));
  const response = await fetch(target, { method: request.method, headers,
    body,
    signal: AbortSignal.any([request.signal, AbortSignal.timeout(295000)]), redirect: "error", cache: "no-store" });
  const resultHeaders = new Headers({ "Cache-Control": "private, no-store", "Content-Type": response.headers.get("content-type") ?? "application/json" });
  for (const name of ["retry-after", "www-authenticate"]) { const value = response.headers.get(name); if (value) resultHeaders.set(name, value); }
  return new Response(response.body, { status: response.status, headers: resultHeaders });
}

export type SharedMediaModel = { id: string; provider: "google" | "gateway" | "azure"; displayName: string; capability: string; mediaPrice: { usd: number; unit: string; variants?: Record<string, number> } };
export async function sharedMediaModel(request: Request, id: string, capability: string) {
  const response = await flowcyMedia(new Request(request.url, { headers: request.headers }), `/api/v1/models?capability=${encodeURIComponent(capability)}`);
  if (!response.ok) throw new Error("SHARED_MEDIA_CATALOG_UNAVAILABLE");
  const { models } = await response.json() as { models: SharedMediaModel[] };
  const model = models.find(model => model.id === id);
  if (!model?.mediaPrice) throw new Error(`MODEL_NOT_ALLOWED:${capability}:${id}`);
  return model;
}
export function sharedMediaRate(model: SharedMediaModel, variant?: string) {
  const price = model.mediaPrice;
  const usd = price.variants ? price.variants[(variant ?? "").toLowerCase()] : price.usd;
  if (!usd || !Number.isFinite(usd) || usd <= 0) throw new Error(`PRICE_NOT_FOUND:${model.id}`);
  return Math.ceil(usd * 1e9);
}
export async function mediaPayload(response: Response) {
  if (!response.ok) throw new Error(`SHARED_MEDIA_${response.status}`);
  return response.json();
}
