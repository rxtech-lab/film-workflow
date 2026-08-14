import "server-only";

function integerEnvironment(name: string, fallback: number, minimum = 0) {
  const raw = process.env[name]?.trim();
  if (!raw) return fallback;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum) throw new Error(`INVALID_BILLING_CONFIG:${name}`);
  return value;
}

export const CREDIT_PACKS = [
  { id: "points_1000", points: 1_000, amountCents: 130 },
  { id: "points_5000", points: 5_000, amountCents: 650 },
  { id: "points_15000", points: 15_000, amountCents: 1_950 },
  { id: "points_50000", points: 50_000, amountCents: 6_500 },
] as const;

export type CreditPackId = typeof CREDIT_PACKS[number]["id"];

export const billingConfig = {
  enabled: process.env.BILLING_ENABLED === "true",
  promotionalPoints: integerEnvironment("INITIAL_PROMOTIONAL_POINTS", 300),
  pointsPerProviderUsd: integerEnvironment("POINTS_PER_PROVIDER_USD", 1_000, 1),
  minChargePoints: integerEnvironment("BILLING_MIN_CHARGE_POINTS", 1, 1),
  reservationMarginBps: integerEnvironment("BILLING_RESERVATION_MARGIN_BPS", 15_000, 10_000),
  chatReservationPoints: integerEnvironment("AI_CHAT_RESERVATION_POINTS", 40, 1),
  imageReservationPoints: integerEnvironment("AI_IMAGE_RESERVATION_POINTS", 60, 1),
  speechReservationPoints: integerEnvironment("AI_SPEECH_RESERVATION_POINTS", 30, 1),
  musicReservationPoints: integerEnvironment("AI_MUSIC_RESERVATION_POINTS", 200, 1),
  transcriptionReservationPoints: integerEnvironment("AI_TRANSCRIPTION_RESERVATION_POINTS", 30, 1),
  automaticTax: process.env.STRIPE_AUTOMATIC_TAX === "true",
} as const;

export const NANO_USD_PER_USD = 1_000_000_000;
export const NANO_USD_PER_POINT = NANO_USD_PER_USD / billingConfig.pointsPerProviderUsd;

if (!Number.isSafeInteger(NANO_USD_PER_POINT)) {
  throw new Error("POINTS_PER_PROVIDER_USD_MUST_DIVIDE_ONE_BILLION");
}

export function creditPack(packId: string) {
  return CREDIT_PACKS.find((pack) => pack.id === packId) ?? null;
}

export function reserveWithMargin(points: number) {
  return Math.ceil(points * billingConfig.reservationMarginBps / 10_000);
}
