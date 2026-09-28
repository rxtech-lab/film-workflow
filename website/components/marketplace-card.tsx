"use client";

import Link from "next/link";
import { Play } from "lucide-react";
import { useRef, useState, type ReactNode } from "react";
import { SfSymbol } from "@/components/sf-symbol";

/**
 * A storefront card whose cover gives way to the preview clip while the
 * pointer (or keyboard focus) is on it — the same behaviour as the app's
 * `MarketplaceItemCard`: muted, looping, fading in over the still once the
 * first frame is ready, with a play badge hinting at it beforehand.
 *
 * The clip is only fetched on the first hover, so a page of cards costs
 * nothing until someone shows interest in one.
 */
export function MarketplaceCard({
  href,
  imageUrl,
  videoUrl,
  symbol,
  price,
  children,
}: {
  href: string;
  imageUrl: string | null;
  /** Null for items without a clip, and for music and sound effects, whose preview is audio. */
  videoUrl: string | null;
  symbol: string;
  price: string;
  children: ReactNode;
}) {
  const video = useRef<HTMLVideoElement>(null);
  const [hovering, setHovering] = useState(false);
  const [mounted, setMounted] = useState(false);
  const [ready, setReady] = useState(false);

  function enter() {
    if (!videoUrl || window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    setHovering(true);
    setMounted(true);
    const element = video.current;
    if (element) {
      element.currentTime = 0;
      // Autoplay of a muted clip is allowed; a rejection just leaves the cover up.
      element.play().catch(() => undefined);
    }
  }

  function leave() {
    setHovering(false);
    setReady(false);
    video.current?.pause();
  }

  return (
    <Link
      href={href}
      onMouseEnter={enter}
      onMouseLeave={leave}
      onFocus={enter}
      onBlur={leave}
      className="group block overflow-hidden rounded-2xl border border-line bg-surface transition-colors hover:border-accent/60"
    >
      <div className="relative aspect-video overflow-hidden bg-elevated">
        {imageUrl ? (
          // Preview stills live on the R2 domain, outside next/image's allowed hosts.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={imageUrl} alt="" loading="lazy" className="h-full w-full object-cover transition-transform duration-500 group-hover:scale-[1.03]" />
        ) : (
          <div className="flex h-full items-center justify-center">
            <SfSymbol name={symbol} size={36} color="#8b8f95" />
          </div>
        )}
        {videoUrl && mounted ? (
          <video
            ref={video}
            src={videoUrl}
            muted
            loop
            playsInline
            autoPlay
            preload="auto"
            aria-label="Preview video"
            onPlaying={() => { if (hovering) setReady(true); }}
            className={`pointer-events-none absolute inset-0 h-full w-full object-cover transition-opacity duration-300 ${ready && hovering ? "opacity-100" : "opacity-0"}`}
          />
        ) : null}
        {videoUrl ? (
          <span
            aria-hidden="true"
            className={`absolute bottom-3 left-3 flex h-6 w-6 items-center justify-center rounded-full bg-black/45 text-white transition-opacity duration-150 ${hovering ? "opacity-0" : "opacity-100"}`}
          >
            <Play size={10} fill="currentColor" />
          </span>
        ) : null}
        <span className="absolute top-3 right-3 rounded-full bg-ink/80 px-2.5 py-0.5 font-mono text-[11px] tracking-[0.08em] backdrop-blur">
          {price}
        </span>
      </div>
      {children}
    </Link>
  );
}
