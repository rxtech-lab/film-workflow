"use client";

import { Shapes } from "lucide-react";
import Image from "next/image";
import { useState } from "react";

export function SfSymbol({
  name,
  size,
  color,
  className,
}: {
  name: string;
  size: number;
  color: string;
  className?: string;
}) {
  const trimmed = name.trim();
  const [failedName, setFailedName] = useState<string | null>(null);
  const failed = failedName === trimmed;

  if (!trimmed || failed) {
    return (
      <span
        title={trimmed ? `${trimmed} — no preview for this symbol` : "No symbol"}
        className={className}
        style={{ display: "inline-flex", lineHeight: 0, opacity: 0.55 }}
      >
        <Shapes aria-hidden="true" style={{ width: size, height: size, color }} strokeWidth={2} />
      </span>
    );
  }

  const src = `/api/sf-symbols?name=${encodeURIComponent(trimmed)}&color=${encodeURIComponent(color)}`;
  return (
    <Image
      src={src}
      alt=""
      aria-hidden="true"
      title={trimmed}
      width={size}
      height={size}
      unoptimized
      className={className}
      style={{ display: "inline-block", flexShrink: 0 }}
      onError={() => setFailedName(trimmed)}
    />
  );
}
