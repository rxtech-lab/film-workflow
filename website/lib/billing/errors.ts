import { requestLocale } from "@/lib/i18n/request";
import { t } from "@/lib/i18n/messages";

export class InsufficientCreditsError extends Error {
  constructor(
    readonly availablePoints: number,
    readonly requiredPoints: number,
  ) {
    super("INSUFFICIENT_POINTS");
    this.name = "InsufficientCreditsError";
  }
}

export async function insufficientCreditsResponse(error: InsufficientCreditsError) {
  return Response.json({
    error: t(await requestLocale(), "error.insufficientCredits"),
    code: "insufficient_points",
    availablePoints: error.availablePoints,
    requiredPoints: error.requiredPoints,
    creditsUrl: "/credits",
  }, { status: 402, headers: { "Cache-Control": "private, no-store", Vary: "Accept-Language" } });
}

