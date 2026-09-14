import { describe, expect, it } from "vitest";
import { DEFAULT_LOCALE, localeHeaders, negotiateLocale, SUPPORTED_LOCALES } from "@/lib/i18n/locale";
import { t } from "@/lib/i18n/messages";
import { localizedField, readTranslations, translationsInput } from "@/lib/i18n/translations";
import { marketplaceFormSchema } from "@/lib/marketplace/form-schema";

describe("Accept-Language negotiation", () => {
  it("matches the spellings a client actually sends for Simplified Chinese", () => {
    for (const header of ["zh", "zh-CN", "zh-Hans", "zh-Hans-CN", "zh-SG", "ZH-HANS-cn"]) {
      expect(negotiateLocale(header)).toBe("zh-Hans");
    }
  });

  it("does not answer a Traditional Chinese request in Simplified", () => {
    expect(negotiateLocale("zh-Hant,zh-TW;q=0.9")).toBe("en");
    // …but honours a Simplified fallback the same header offers further down.
    expect(negotiateLocale("zh-TW,zh-Hans;q=0.5")).toBe("zh-Hans");
  });

  it("ranks by q-weight, not by order", () => {
    expect(negotiateLocale("en;q=0.3,zh-CN;q=0.9")).toBe("zh-Hans");
    expect(negotiateLocale("zh-CN;q=0.2,en;q=0.8")).toBe("en");
    // Equal weights keep the order the client wrote.
    expect(negotiateLocale("zh-CN,en")).toBe("zh-Hans");
  });

  it("falls back to the source language on anything it cannot use", () => {
    for (const header of [null, undefined, "", "*", "fr-FR,de;q=0.8", "zh-CN;q=0", "not a header"]) {
      expect(negotiateLocale(header)).toBe(DEFAULT_LOCALE);
    }
  });

  it("tells caches that the answer depends on the request's language", () => {
    // Read back through `Headers`, which is how they reach the wire: the merge
    // normalises names, so the case they are written in here does not matter.
    const plain = new Headers(localeHeaders("zh-Hans"));
    expect(plain.get("content-language")).toBe("zh-Hans");
    expect(plain.get("vary")).toBe("Accept-Language");
    const cached = new Headers(localeHeaders("en", { "Cache-Control": "public, max-age=300" }));
    expect(cached.get("content-language")).toBe("en");
    expect(cached.get("vary")).toBe("Accept-Language");
    expect(cached.get("cache-control")).toBe("public, max-age=300");
  });
});

describe("stored translations", () => {
  const parse = (input: unknown) => translationsInput(["title", "description"]).parse(input);

  it("keeps the fields it was given and drops everything else", () => {
    expect(parse({ "zh-Hans": { title: " 极简片头 ", description: "", slug: "nope" } })).toEqual({ "zh-Hans": { title: "极简片头" } });
    // A locale this deploy does not serve, and the base locale, are not stored.
    expect(parse({ fr: { title: "Non" }, en: { title: "No" } })).toEqual({});
    expect(parse(undefined)).toEqual({});
  });

  it("survives a row that was hand-edited into the wrong shape", () => {
    expect(readTranslations({ "zh-Hans": { title: 42, description: "  ", label: "标签" } })).toEqual({ "zh-Hans": { label: "标签" } });
    expect(readTranslations("nonsense")).toEqual({});
    expect(readTranslations(null)).toEqual({});
  });

  it("reads a field through to the base column when nobody has translated it", () => {
    const translations = { "zh-Hans": { name: "舒缓" } };
    expect(localizedField(translations, "zh-Hans", "name", "Relaxing")).toBe("舒缓");
    expect(localizedField(translations, "zh-Hans", "icon", "folder")).toBe("folder");
    expect(localizedField(translations, "en", "name", "Relaxing")).toBe("Relaxing");
    expect(localizedField({}, "zh-Hans", "name", "Relaxing")).toBe("Relaxing");
  });
});

describe("message catalog", () => {
  it("translates what it has and falls back to the source string otherwise", () => {
    expect(t("zh-Hans", "error.marketplace.notFound")).toBe("找不到该市场项目。");
    expect(t("en", "error.marketplace.notFound")).toBe("Marketplace item not found.");
  });

  it("fills the placeholders a message carries", () => {
    expect(t("en", "authoring.shotSourceRequired", { shot: "Opening" })).toBe("Opening needs a media or Remotion source.");
    // A placeholder with nothing to fill it is left alone rather than printed as "undefined".
    expect(t("en", "authoring.shotSourceRequired")).toContain("{shot}");
  });
});

describe("the authoring form, per locale", () => {
  it("is built in the language asked for", () => {
    const zh = marketplaceFormSchema("zh-Hans");
    expect(zh.sections[0].title).toBe("详情");
    expect(zh.sections[0].fields.find((field) => field.id === "title")?.title).toBe("标题");
    expect(zh.layouts.find((layout) => layout.kind === "font")?.content.title).toBe("字体文件");
  });

  it("offers a box for every translatable field in every language the app ships", () => {
    const ids = marketplaceFormSchema().sections.find((section) => section.id === "translations")?.fields.map((field) => field.id);
    expect(ids).toEqual(["translations.zh-Hans.title", "translations.zh-Hans.description"]);
    // The ids are paths into `ItemInput.translations`, one per non-default locale.
    expect(SUPPORTED_LOCALES.filter((locale) => locale !== DEFAULT_LOCALE)).toEqual(["zh-Hans"]);
  });

  it("titles a translated box with its language, so an editor knows which box is which", () => {
    expect(marketplaceFormSchema().sections[1].fields[0].title).toBe("Title · 简体中文");
    expect(marketplaceFormSchema("zh-Hans").sections[1].fields[0].title).toBe("标题 · 简体中文");
  });
});
