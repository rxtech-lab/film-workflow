/**
 * Which language a request is answered in.
 *
 * The macOS app sends `Accept-Language` on every call it makes (see
 * `BackendClient` and `MarketplaceClient` in the app), so the wire carries the
 * same language the app's own UI is drawn in. Everything the server writes for
 * a person to read — taxonomy labels, item titles, form field titles, error
 * messages — is resolved against the locale this module picks.
 *
 * The set is deliberately the app's set: `Localizable.xcstrings` ships `en` and
 * `zh-Hans`, and a locale the app cannot draw is not worth translating on the
 * server. Anything else negotiates down to `en`.
 */
export const SUPPORTED_LOCALES = ["en", "zh-Hans"] as const;
export type Locale = (typeof SUPPORTED_LOCALES)[number];

/** The language the base columns and the source strings are written in. */
export const DEFAULT_LOCALE: Locale = "en";

export function isLocale(value: string): value is Locale {
  return (SUPPORTED_LOCALES as readonly string[]).includes(value);
}

/**
 * Simplified Chinese is asked for in a dozen spellings — `zh`, `zh-CN`,
 * `zh-Hans`, `zh-Hans-CN`, `zh-SG` — and Traditional in a few more. Only the
 * Simplified ones map onto what we have; `zh-Hant`, `zh-TW`, `zh-HK` and
 * `zh-MO` fall through to the next tag the client offered rather than being
 * served Simplified text they did not ask for.
 */
function canonical(tag: string): Locale | undefined {
  const subtags = tag.toLowerCase().split("-");
  const [language, ...rest] = subtags;
  if (language === "en") return "en";
  if (language !== "zh") return undefined;
  if (rest.some((subtag) => ["hant", "tw", "hk", "mo"].includes(subtag))) return undefined;
  return "zh-Hans";
}

/**
 * The best locale for one `Accept-Language` value, by descending q-weight.
 * A malformed q, or a tag we have nothing for, is skipped rather than throwing;
 * `*` means "anything", which is the default. Absent or unmatched: `en`.
 */
export function negotiateLocale(header: string | null | undefined): Locale {
  if (!header) return DEFAULT_LOCALE;
  const candidates = header
    .split(",")
    .map((part, index) => {
      const [tag, ...parameters] = part.trim().split(";");
      const quality = parameters
        .map((parameter) => /^\s*q\s*=\s*([0-9.]+)\s*$/i.exec(parameter))
        .find(Boolean);
      const weight = quality ? Number.parseFloat(quality[1]) : 1;
      return { tag: tag.trim(), weight: Number.isFinite(weight) ? weight : 0, index };
    })
    .filter((candidate) => candidate.tag.length > 0 && candidate.weight > 0)
    // Ties keep the order the client wrote them in.
    .sort((a, b) => b.weight - a.weight || a.index - b.index);
  for (const candidate of candidates) {
    if (candidate.tag === "*") return DEFAULT_LOCALE;
    const locale = canonical(candidate.tag);
    if (locale) return locale;
  }
  return DEFAULT_LOCALE;
}

/**
 * What a localized response advertises. `Vary` is what keeps a cache from
 * handing a Chinese page to the next English client; `Content-Language` tells
 * the client which way the negotiation went.
 */
export function localeHeaders(locale: Locale, extra?: HeadersInit) {
  return { "Content-Language": locale, Vary: "Accept-Language", ...Object.fromEntries(new Headers(extra)) };
}
