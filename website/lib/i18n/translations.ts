import { z } from "zod";
import { DEFAULT_LOCALE, isLocale, SUPPORTED_LOCALES, type Locale } from "./locale";

/**
 * Admin-authored text in the languages other than the one the base column is
 * written in, as stored in the `translations` jsonb of `marketplace_items`,
 * `marketplace_categories` and `marketplace_kinds`:
 *
 *     { "zh-Hans": { "title": "极简片头", "description": "…" } }
 *
 * The base column stays the source of truth: a locale with no entry, or an
 * entry left blank, reads through to it. Nothing here is ever machine
 * translated — a missing translation shows the original rather than a guess.
 */
export type Translations = Partial<Record<Locale, Record<string, string>>>;

/** Locales an admin form offers, i.e. everything but the one the base columns hold. */
export const TRANSLATABLE_LOCALES = SUPPORTED_LOCALES.filter((locale) => locale !== DEFAULT_LOCALE);

/** How each translatable locale names itself in the admin forms. */
export const localeNames: Record<Locale, string> = { en: "English", "zh-Hans": "简体中文" };

/**
 * What an admin may send. Unknown locales and blank strings are dropped rather
 * than rejected, so a client that knows one more language than this deploy —
 * or a form that submits empty boxes for every field — is not an error.
 */
export function translationsInput(fields: readonly string[]) {
  return z.record(z.string(), z.record(z.string(), z.string().trim().max(4000)))
    .default({})
    .transform((input): Translations => {
      const result: Translations = {};
      for (const [locale, values] of Object.entries(input)) {
        if (!isLocale(locale) || locale === DEFAULT_LOCALE) continue;
        const kept: Record<string, string> = {};
        for (const field of fields) {
          const value = values?.[field]?.trim();
          if (value) kept[field] = value;
        }
        if (Object.keys(kept).length > 0) result[locale] = kept;
      }
      return result;
    });
}

/** The stored shape, parsed defensively: a hand-edited row never breaks a read. */
export function readTranslations(value: unknown): Translations {
  if (!value || typeof value !== "object") return {};
  const result: Translations = {};
  for (const [locale, values] of Object.entries(value as Record<string, unknown>)) {
    if (!isLocale(locale) || !values || typeof values !== "object") continue;
    const kept: Record<string, string> = {};
    for (const [field, text] of Object.entries(values as Record<string, unknown>)) {
      if (typeof text === "string" && text.trim()) kept[field] = text;
    }
    if (Object.keys(kept).length > 0) result[locale] = kept;
  }
  return result;
}

/** One field in `locale`, or the base column when it has no translation. */
export function localizedField(translations: unknown, locale: Locale, field: string, base: string): string {
  if (locale === DEFAULT_LOCALE) return base;
  return readTranslations(translations)[locale]?.[field] ?? base;
}
