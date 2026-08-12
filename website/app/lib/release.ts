export type Release = {
  version: string;
  url: string;
  dmgUrl: string;
  size: string;
  date: string;
};

const REPO = "rxtech-lab/film-workflow";
const APPCAST = "https://update.filmstudio.rxlab.app/appcast.xml";

function tag(xml: string, name: string): string | undefined {
  const m = xml.match(
    new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`),
  );
  return m?.[1].trim();
}

function attr(el: string, name: string): string | undefined {
  return el.match(new RegExp(`${name}="([^"]*)"`))?.[1];
}

/**
 * The Sparkle appcast is the same feed the app updates from, so the site and
 * the in-app updater can never disagree about what "latest" means.
 */
export async function getLatestRelease(): Promise<Release> {
  const res = await fetch(APPCAST, { next: { revalidate: 3600 } });
  if (!res.ok) {
    throw new Error(`appcast fetch failed: ${res.status} ${res.statusText}`);
  }

  const xml = await res.text();
  const items = [...xml.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]);
  if (items.length === 0) throw new Error("appcast has no <item>");

  // Newest by Sparkle's build number, not by feed order — the feed keeps history.
  const item = items.reduce((newest, candidate) =>
    Number(tag(candidate, "sparkle:version") ?? 0) >
    Number(tag(newest, "sparkle:version") ?? 0)
      ? candidate
      : newest,
  );

  const version = tag(item, "sparkle:shortVersionString") ?? tag(item, "title");
  const enclosure = item.match(/<enclosure\b[^>]*>/)?.[0];
  const dmgUrl = enclosure && attr(enclosure, "url");
  const pubDate = tag(item, "pubDate");
  const length = Number(enclosure && attr(enclosure, "length"));
  if (!version || !dmgUrl || !pubDate || !(length > 0)) {
    throw new Error(
      "appcast item is missing version, enclosure url/length, or date",
    );
  }

  return {
    version,
    url: `https://github.com/${REPO}/releases/tag/v${version}`,
    dmgUrl,
    size: `${Math.round(length / 1_000_000)} MB`,
    date: new Date(pubDate).toLocaleDateString("en-US", {
      year: "numeric",
      month: "long",
      day: "numeric",
      timeZone: "UTC",
    }),
  };
}
