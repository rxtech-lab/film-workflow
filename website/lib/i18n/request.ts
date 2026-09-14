import "server-only";

import { DEFAULT_LOCALE, negotiateLocale, type Locale } from "./locale";

/**
 * The locale of the request being handled.
 *
 * Route handlers pass their `Request`. Server actions and the helpers that
 * build error responses have none to hand, so they read the incoming headers
 * instead — which is why this lives apart from `locale.ts`: that module is
 * plain data and is bundled into client components, and `next/headers` must
 * never follow it there.
 *
 * Outside a request — a script, a unit test — the header read throws and the
 * source language stands.
 */
export async function requestLocale(request?: Request): Promise<Locale> {
  if (request) return negotiateLocale(request.headers.get("accept-language"));
  try {
    const { headers } = await import("next/headers");
    return negotiateLocale((await headers()).get("accept-language"));
  } catch {
    return DEFAULT_LOCALE;
  }
}
