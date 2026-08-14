export class InsufficientCreditsError extends Error {
  constructor(
    readonly availablePoints: number,
    readonly requiredPoints: number,
  ) {
    super("INSUFFICIENT_POINTS");
    this.name = "InsufficientCreditsError";
  }
}

export function insufficientCreditsResponse(error: InsufficientCreditsError) {
  return Response.json({
    error: "You do not have enough points for this operation.",
    code: "insufficient_points",
    availablePoints: error.availablePoints,
    requiredPoints: error.requiredPoints,
    creditsUrl: "/credits",
  }, { status: 402, headers: { "Cache-Control": "private, no-store" } });
}

