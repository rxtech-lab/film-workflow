import { aiRouteError, providerError } from "@/lib/ai/http";
import { requireApiUser } from "@/lib/auth/bearer";

export async function GET(request: Request) {
  try {
    await requireApiUser(request);
    const provider = new URL(request.url).searchParams.get("provider");
    if (provider !== "azure") return Response.json({ code: "bad_request", error: "Only Azure has a remote voice catalog." }, { status: 400 });
    const key = process.env.AZURE_SPEECH_KEY?.trim();
    const configured = process.env.AZURE_SPEECH_REGION?.trim() || process.env.AZURE_SPEECH_ENDPOINT?.trim();
    if (!key || !configured) throw new Error("AZURE_SPEECH_NOT_CONFIGURED");
    let region = configured;
    try { region = new URL(configured).host.split(".")[0]; } catch {}
    const response = await fetch(`https://${region}.tts.speech.microsoft.com/cognitiveservices/voices/list`, { headers: { "Ocp-Apim-Subscription-Key": key }, signal: AbortSignal.timeout(30_000) });
    if (!response.ok) await providerError(response);
    return new Response(await response.text(), { headers: { "Content-Type": "application/json", "Cache-Control": "private, max-age=0", "CDN-Cache-Control": "s-maxage=86400" } });
  } catch (cause) { return aiRouteError(cause); }
}
