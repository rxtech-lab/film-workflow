/**
 * Absolute base for metadata URLs (OG image, canonical, twitter card).
 *
 * Order of preference:
 *   1. NEXT_PUBLIC_SITE_URL — set this once a custom domain is attached.
 *   2. The Vercel deployment URL: the project's production domain on
 *      production builds, the per-deployment URL on previews.
 *   3. localhost, for local development.
 *
 * Vercel's system variables carry no protocol, so https:// is prefixed here.
 */
export function getSiteUrl(): string {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/$/, "");

  const vercelHost =
    process.env.VERCEL_ENV === "production"
      ? (process.env.VERCEL_PROJECT_PRODUCTION_URL ?? process.env.VERCEL_URL)
      : process.env.VERCEL_URL;
  if (vercelHost) return `https://${vercelHost}`;

  return `http://localhost:${process.env.PORT ?? 3000}`;
}
