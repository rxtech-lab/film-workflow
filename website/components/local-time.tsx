"use client";

import { useSyncExternalStore } from "react";

/** What the server renders, and what a client without JS keeps. Labelled, because it is not the reader's zone. */
const utc = new Intl.DateTimeFormat("en-US", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" });

/** The timestamp never changes on its own, so there is nothing to subscribe to. */
const subscribe = () => () => {};

/**
 * A timestamp in the reader's own timezone.
 *
 * The pages that use this are server components, so the markup React hydrates
 * against is necessarily the server's zone. `useSyncExternalStore` is the hook
 * built for exactly that split: it renders the server snapshot through
 * hydration, then switches to the client's, so the reader gets local time
 * without a hydration mismatch.
 */
export function LocalTime({ value, className }: { value: string; className?: string }) {
  const text = useSyncExternalStore(
    subscribe,
    () => new Date(value).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" }),
    () => `${utc.format(new Date(value))} UTC`,
  );

  return <time dateTime={value} className={className}>{text}</time>;
}
