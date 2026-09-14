import "server-only";

import { createHash } from "node:crypto";
import { getCurrentUser, isAdmin, type AppUser } from "@/lib/auth";
import { requestLocale } from "@/lib/i18n/request";
import { t } from "@/lib/i18n/messages";

export class UnauthorizedError extends Error {
  constructor() {
    super("Authentication is required");
    this.name = "UnauthorizedError";
  }
}

export class ForbiddenError extends Error {
  constructor() {
    super("This action requires the admin role");
    this.name = "ForbiddenError";
  }
}

type CachedIdentity = { user: AppUser; expiresAt: number };
const identities = new Map<string, CachedIdentity>();
const IDENTITY_TTL_MS = 60_000;

function tokenCacheKey(token: string) {
  return createHash("sha256").update(token).digest("hex");
}

function issuer() {
  const value = process.env.AUTH_ISSUER?.trim().replace(/\/$/, "");
  if (!value) throw new Error("AUTH_ISSUER_NOT_CONFIGURED");
  return value;
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
}

export async function verifyBearerToken(token: string): Promise<AppUser | null> {
  const trimmed = token.trim();
  if (!trimmed) return null;
  const key = tokenCacheKey(trimmed);
  const now = Date.now();
  const cached = identities.get(key);
  if (cached && cached.expiresAt > now) return cached.user;

  const response = await fetch(`${issuer()}/api/oauth/userinfo`, {
    headers: { Authorization: `Bearer ${trimmed}`, Accept: "application/json" },
    cache: "no-store",
    signal: AbortSignal.timeout(10_000),
  });
  if (!response.ok) return null;
  const body = await response.json() as Record<string, unknown>;
  const id = typeof body.sub === "string" ? body.sub : typeof body.id === "string" ? body.id : "";
  if (!id) return null;
  const user: AppUser = {
    id,
    name: typeof body.name === "string"
      ? body.name
      : typeof body.preferred_username === "string"
        ? body.preferred_username
        : "RxLab user",
    email: typeof body.email === "string" ? body.email : "",
    roles: stringArray(body.roles),
  };
  identities.set(key, { user, expiresAt: now + IDENTITY_TTL_MS });
  if (identities.size > 500) {
    for (const [candidate, value] of identities) {
      if (value.expiresAt <= now) identities.delete(candidate);
    }
  }
  return user;
}

export async function getRequestUser(request: Request): Promise<AppUser | null> {
  const authorization = request.headers.get("authorization");
  if (authorization?.toLowerCase().startsWith("bearer ")) {
    return verifyBearerToken(authorization.slice(7));
  }
  return getCurrentUser();
}

export async function requireApiUser(request: Request): Promise<AppUser> {
  const user = await getRequestUser(request);
  if (!user) throw new UnauthorizedError();
  return user;
}

export async function requireAdminUser(request: Request): Promise<AppUser> {
  const user = await requireApiUser(request);
  if (!isAdmin(user)) throw new ForbiddenError();
  return user;
}

/**
 * The refusals, in the caller's language. Both read `Accept-Language` off the
 * request being handled rather than taking it as an argument, so every route
 * that already returns them keeps doing so unchanged.
 */
export async function forbiddenResponse() {
  return Response.json(
    { code: "forbidden", error: t(await requestLocale(), "error.forbidden") },
    { status: 403, headers: { "Cache-Control": "private, no-store", Vary: "Accept-Language" } },
  );
}

export async function unauthorizedResponse() {
  return Response.json(
    { code: "unauthorized", error: t(await requestLocale(), "error.unauthorized") },
    { status: 401, headers: { "WWW-Authenticate": "Bearer", "Cache-Control": "private, no-store", Vary: "Accept-Language" } },
  );
}
