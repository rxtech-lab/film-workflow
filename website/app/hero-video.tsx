"use client";

import { useEffect, useRef } from "react";

/** How much film the whole hero track spans, in seconds. Lower reads calmer. */
const SPAN = 9;

/**
 * The trailer running behind the title. The film is not played — it is
 * threaded onto the scroll: a given scroll position always shows the same
 * frame, so scrolling down runs it forward, scrolling up winds it back, and
 * leaving and returning picks up exactly where you left it.
 */
export default function HeroVideo() {
  const ref = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    const video = ref.current;
    const track = video?.closest("section");
    if (!video || !track) return;
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    let frame = 0;
    let onScreen = true;

    /** 0 → 1 across the pinned part of the hero track. */
    const progress = () => {
      const rect = track.getBoundingClientRect();
      const travel = rect.height - window.innerHeight;
      if (travel <= 0) return 0;
      return Math.min(Math.max(-rect.top / travel, 0), 1);
    };

    const target = () => {
      const span = Math.min(SPAN, video.duration || SPAN);
      return progress() * span;
    };

    const step = () => {
      const want = target();

      // The frame is a pure function of the scroll position — no easing, no
      // momentum, so leaving and coming back lands on the same frame.
      if (Math.abs(want - video.currentTime) < 0.005) {
        frame = 0;
        return;
      }
      // A pending seek would swallow the next one, so let it land first.
      if (!video.seeking) video.currentTime = want;
      frame = requestAnimationFrame(step);
    };

    const run = () => {
      if (!onScreen || frame) return;
      frame = requestAnimationFrame(step);
    };

    const stop = () => {
      if (!frame) return;
      cancelAnimationFrame(frame);
      frame = 0;
    };

    // Nothing to decode once the hero has scrolled away.
    const observer = new IntersectionObserver(
      ([entry]) => {
        onScreen = entry.isIntersecting;
        if (onScreen) run();
        else stop();
      },
      { threshold: 0 },
    );
    observer.observe(video);

    const ready = () => {
      video.currentTime = target();
    };
    if (video.readyState >= 1) ready();
    else video.addEventListener("loadedmetadata", ready, { once: true });

    window.addEventListener("scroll", run, { passive: true });
    window.addEventListener("resize", run, { passive: true });
    return () => {
      window.removeEventListener("scroll", run);
      window.removeEventListener("resize", run);
      observer.disconnect();
      stop();
    };
  }, []);

  return (
    <video
      ref={ref}
      src="https://s3.rxlab.app/filmstudio/trailer-1080p.mp4"
      poster="/videos/trailer-poster.jpg"
      muted
      playsInline
      preload="auto"
      disablePictureInPicture
      aria-hidden="true"
      className="absolute inset-0 h-full w-full object-cover"
    />
  );
}
