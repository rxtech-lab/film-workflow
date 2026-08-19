import "server-only";

import type { AppUser } from "@/lib/auth";
import { closeReservation, reserveCredits } from "@/lib/billing/repository";
import type { MeteringContext } from "@/lib/billing/usage";
import type { Capability } from "@/lib/db/schema";

export async function withMeteredOperation<T>(input: {
  user: AppUser;
  feature: string;
  capability: Capability;
  operationKey: string;
  reservePoints: number;
  scopeId?: string | null;
  run: (context: MeteringContext) => Promise<T>;
}) {
  const reservation = await reserveCredits({
    user: input.user,
    operationKey: input.operationKey,
    feature: input.feature,
    points: input.reservePoints,
    scopeId: input.scopeId,
  });
  const context: MeteringContext = {
    userId: input.user.id,
    reservationId: reservation?.id ?? null,
    feature: input.feature,
    capability: input.capability,
    operationId: reservation?.id ?? input.operationKey,
  };
  try {
    const value = await input.run(context);
    if (reservation) await closeReservation({ reservationId: reservation.id, userId: input.user.id, success: true });
    return { value, reservationId: reservation?.id ?? null };
  } catch (cause) {
    if (reservation) await closeReservation({ reservationId: reservation.id, userId: input.user.id, success: false });
    throw cause;
  }
}
