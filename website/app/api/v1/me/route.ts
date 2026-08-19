import { requireApiUser, unauthorizedResponse, UnauthorizedError } from "@/lib/auth/bearer";
import { billingConfig } from "@/lib/billing/config";
import { getBalance } from "@/lib/billing/subscription";
import { db } from "@/lib/db";
import { deviceSessions } from "@/lib/db/schema";

function platform(value: string | null): "macos" | "ios" | null {
  return value === "macos" || value === "ios" ? value : null;
}

async function sessionID(userID: string, deviceID: string) {
  const bytes = new TextEncoder().encode(`${userID}\0${deviceID}`);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function GET(request: Request) {
  try {
    const user = await requireApiUser(request);
    const clientPlatform = platform(request.headers.get("x-client-platform"));
    const deviceId = request.headers.get("x-client-device-id")?.trim();
    if (clientPlatform && deviceId) {
      const now = new Date();
      const id = await sessionID(user.id, deviceId.slice(0, 200));
      await db.insert(deviceSessions).values({
        id,
        userId: user.id,
        platform: clientPlatform,
        appVersion: request.headers.get("x-client-version")?.slice(0, 80) ?? null,
        deviceName: request.headers.get("x-client-device-name")?.slice(0, 160) ?? null,
        lastSeenAt: now,
        createdAt: now,
      }).onConflictDoUpdate({
        target: deviceSessions.id,
        set: { platform: clientPlatform, appVersion: request.headers.get("x-client-version")?.slice(0, 80) ?? null, deviceName: request.headers.get("x-client-device-name")?.slice(0, 160) ?? null, lastSeenAt: now },
      });
    }
    const balance = await getBalance(user);
    const origin = new URL(request.url).origin;
    return Response.json({
      user,
      billing: {
        enabled: billingConfig.enabled,
        balancePoints: balance.amount,
        reservedPoints: balance.amount - balance.available,
        availablePoints: balance.available,
        pointsPerUsd: billingConfig.pointsPerProviderUsd,
      },
      urls: { credits: `${origin}/credits?app=1`, usage: `${origin}/usage` },
    }, { headers: { "Cache-Control": "private, no-store" } });
  } catch (cause) {
    if (cause instanceof UnauthorizedError) return unauthorizedResponse();
    throw cause;
  }
}
