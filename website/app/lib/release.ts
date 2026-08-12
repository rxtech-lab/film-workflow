export type Release = {
  version: string;
  url: string;
  dmgUrl: string;
  size: string;
  date: string;
};

const REPO = "rxtech-lab/film-workflow";

// Shipped values for v1.4.0 — used until the GitHub API answers, and if it never does.
const FALLBACK: Release = {
  version: "1.4.0",
  url: `https://github.com/${REPO}/releases/tag/v1.4.0`,
  dmgUrl: `https://github.com/${REPO}/releases/download/v1.4.0/RxFilmStudio.dmg`,
  size: "119 MB",
  date: "August 12, 2026",
};

type GitHubRelease = {
  tag_name: string;
  html_url: string;
  published_at: string;
  assets: { name: string; browser_download_url: string; size: number }[];
};

export async function getLatestRelease(): Promise<Release> {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${REPO}/releases/latest`,
      {
        headers: { Accept: "application/vnd.github+json" },
        next: { revalidate: 3600 },
      },
    );
    if (!res.ok) return FALLBACK;

    const data = (await res.json()) as GitHubRelease;
    const dmg = data.assets.find((a) => a.name.endsWith(".dmg"));
    if (!dmg) return FALLBACK;

    return {
      version: data.tag_name.replace(/^v/, ""),
      url: data.html_url,
      dmgUrl: dmg.browser_download_url,
      size: `${Math.round(dmg.size / 1_000_000)} MB`,
      date: new Date(data.published_at).toLocaleDateString("en-US", {
        year: "numeric",
        month: "long",
        day: "numeric",
        timeZone: "UTC",
      }),
    };
  } catch {
    return FALLBACK;
  }
}
