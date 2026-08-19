import { z } from "zod";
import { requireCatalogModel } from "@/lib/ai/catalog";
import { aiRouteError, noStoreHeaders, providerError } from "@/lib/ai/http";
import { withMeteredOperation } from "@/lib/ai/meter";
import { requireApiUser } from "@/lib/auth/bearer";
import { billingConfig, reserveWithMargin } from "@/lib/billing/config";
import { getBalance } from "@/lib/billing/subscription";
import { recordAiUsage } from "@/lib/billing/usage";

export const maxDuration = 300;

const schema = z.object({
  model: z.string().min(1).max(160),
  messages: z.array(z.record(z.string(), z.unknown())).min(1).max(500),
  tools: z.array(z.record(z.string(), z.unknown())).max(200).optional(),
  tool_choice: z.unknown().optional(),
  temperature: z.number().min(0).max(2).optional(),
  max_tokens: z.number().int().positive().max(128_000).optional(),
  response_format: z.unknown().optional(),
  stream: z.literal(false).optional(),
}).passthrough();

export async function POST(request: Request) {
  try {
    const user = await requireApiUser(request);
    const parsed = schema.safeParse(await request.json().catch(() => null));
    if (!parsed.success) return Response.json({ code: "bad_request", error: parsed.error.issues[0]?.message ?? "Invalid chat request" }, { status: 400, headers: noStoreHeaders() });
    const model = await requireCatalogModel(parsed.data.model, "chat");
    if (model.provider !== "gateway") throw new Error("MODEL_NOT_ALLOWED:chat");
    const key = process.env.AI_GATEWAY_API_KEY?.trim();
    if (!key) throw new Error("AI_GATEWAY_NOT_CONFIGURED");
    const operationKey = request.headers.get("idempotency-key")?.slice(0, 180) || `chat:${user.id}:${crypto.randomUUID()}`;
    const { value } = await withMeteredOperation({ user, feature: `Chat · ${model.displayName}`, capability: "chat", operationKey, reservePoints: reserveWithMargin(billingConfig.chatReservationPoints), run: async (context) => {
      const response = await fetch("https://ai-gateway.vercel.sh/v1/chat/completions", { method: "POST", headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json", "http-referer": process.env.NEXT_PUBLIC_SITE_URL ?? "https://filmstudio.rxlab.app", "x-title": "RxFilm Studio" }, body: JSON.stringify({ ...parsed.data, stream: false }), signal: AbortSignal.timeout(290_000) });
      if (!response.ok) await providerError(response);
      const body = await response.json() as { id?: string; usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number }; [key: string]: unknown };
      const raw = body.usage;
      const usage = { inputTokens: raw?.prompt_tokens ?? 0, outputTokens: raw?.completion_tokens ?? 0, totalTokens: raw?.total_tokens ?? ((raw?.prompt_tokens ?? 0) + (raw?.completion_tokens ?? 0)) };
      const event = await recordAiUsage({ context, model: model.id, responseId: body.id, usage, eventId: "completion" });
      return { body, chargedPoints: event?.chargedPoints ?? 0 };
    } });
    const balance = await getBalance(user);
    return Response.json({ ...value.body, rxlab_usage: { chargedPoints: value.chargedPoints, availablePoints: balance.available } }, { headers: noStoreHeaders() });
  } catch (cause) { return aiRouteError(cause); }
}
