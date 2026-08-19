import { proxy as authProxy } from "@/lib/auth";
import type { NextFetchEvent, NextRequest } from "next/server";

export default function proxy(request: NextRequest, event: NextFetchEvent) {
  return authProxy(request, event);
}

/**
 * The proxy only refreshes the browser's session cookie — it never blocks a
 * request — so the matcher covers the account pages, `/login`, and the
 * cookie-authenticated `api/billing` routes. `api/v1`, `api/workflows`, and the
 * workflow runtime's `.well-known` endpoints are excluded because the macOS
 * client and the workflow runner authenticate with a bearer token rather than a
 * cookie; running the session refresh on those hot-path requests would cost
 * latency for nothing.
 */
export const config = {
  matcher: [
    "/((?!api/auth|api/v1|api/workflows|\\.well-known|_next/static|_next/image|favicon.ico|sitemap.xml|robots.txt|.*\\.(?:svg|png|jpg|jpeg|gif|webp)$).*)",
  ],
};
