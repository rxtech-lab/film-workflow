import { SUPPORTED_LOCALES, type Locale } from "@/lib/i18n/locale";
import { t, type MessageKey } from "@/lib/i18n/messages";
import type { Translations } from "@/lib/i18n/translations";
import type { MarketplaceKind, MediaType } from "./schema";

/**
 * The built-in names for the taxonomy, in every language the app ships.
 *
 * A kind's label and a category's name normally come out of the database,
 * where an admin owns both the text and its translations. These are what
 * stands in when there is no row to read — a kind whose seed has not run, and
 * the media-type shelves, which have no table of their own — expressed as the
 * same `translations` shape the rows carry so the caller resolves all three
 * the same way.
 */
function builtIn(field: string, key: (locale: Locale) => MessageKey): Translations {
  const translations: Translations = {};
  for (const locale of SUPPORTED_LOCALES) translations[locale] = { [field]: t(locale, key(locale)) };
  return translations;
}

/** How one item kind names itself in the app's sidebar, per locale. */
export function kindDefaultTranslations(kind: MarketplaceKind): Translations {
  return builtIn("label", () => `kind.${kind}.label` as MessageKey);
}

/** How Footage's sub-shelves name themselves, per locale. */
export function mediaTypeDefaultTranslations(mediaType: MediaType): Translations {
  return builtIn("label", () => `mediaType.${mediaType}.label` as MessageKey);
}

/** One item kind as the authoring form names it, e.g. "Sound effect" / "音效". */
export function kindName(locale: Locale, kind: MarketplaceKind) {
  return t(locale, `kind.${kind}.name` as MessageKey);
}
