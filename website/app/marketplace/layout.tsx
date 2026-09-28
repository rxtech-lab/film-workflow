import type { Metadata } from "next";
import Link from "next/link";
import { getCurrentUser } from "@/lib/auth";
import { getLatestRelease } from "../lib/release";
import { Mark } from "../mark";

export const metadata: Metadata = {
  title: "Marketplace — RxFilmStudio",
  description: "Footage, music, sound effects, fonts, transitions and Remotion compositions you can drop straight into RxFilmStudio.",
  alternates: { canonical: "/marketplace" },
};

/**
 * The public storefront. Anyone can browse; buying and installing happen in
 * the app, so the header's call to action is the download.
 */
export default async function MarketplaceLayout({ children }: LayoutProps<"/marketplace">) {
  const [release, user] = await Promise.all([getLatestRelease(), getCurrentUser()]);
  return (
    <div className="flex min-h-screen flex-col">
      <header className="sticky top-0 z-50 border-b border-line bg-ink/85 backdrop-blur">
        <nav className="mx-auto flex max-w-6xl items-center justify-between px-6 py-4">
          <div className="flex items-center gap-5">
            <Link href="/" className="flex items-center gap-3">
              <Mark />
              <span className="font-mono text-[11px] tracking-[0.26em] uppercase">
                RxFilm<span className="text-muted">Studio</span>
              </span>
            </Link>
            <Link href="/marketplace" className="font-mono text-[11px] tracking-[0.14em] text-accent uppercase">
              Marketplace
            </Link>
          </div>
          <div className="flex items-center gap-3 sm:gap-5">
            <Link
              href={user ? "/dashboard" : "/login"}
              className="max-w-[9rem] truncate font-mono text-[11px] tracking-[0.14em] text-muted transition-colors hover:text-accent"
            >
              {user ? user.name : "Sign in"}
            </Link>
            <a href={release.dmgUrl} className="rounded-full bg-fg px-4 py-1.5 text-sm font-medium text-ink transition-opacity hover:opacity-80">
              Download
            </a>
          </div>
        </nav>
      </header>
      <main className="mx-auto w-full max-w-6xl flex-1 px-6 py-12">{children}</main>
      <footer className="border-t border-line px-6 py-10">
        <div className="mx-auto flex max-w-6xl flex-col items-center justify-between gap-5 font-mono text-[11px] tracking-[0.14em] text-muted uppercase sm:flex-row">
          <div className="flex items-center gap-3">
            <Mark />
            <span>RxFilmStudio</span>
          </div>
          <p>Buy and install from inside the app · macOS · Apple Silicon</p>
        </div>
      </footer>
    </div>
  );
}
