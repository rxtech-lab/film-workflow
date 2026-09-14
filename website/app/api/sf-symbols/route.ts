import { getSymbolDefinition, searchSymbols } from "@/lib/sf-symbols.server";

export const runtime = "nodejs";

const DEFAULT_COLOR = "#e5e7eb";

function safeColor(value: string | null): string {
  if (value === "currentColor" || (value && /^#[\da-f]{3,8}$/i.test(value))) return value;
  return DEFAULT_COLOR;
}

function escapeAttribute(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll('"', "&quot;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function renderSymbolSvg(
  definition: NonNullable<ReturnType<typeof getSymbolDefinition>>,
  color: string,
): string {
  const paths = definition.svgPathData
    .map((path) => {
      const opacity = path.fillOpacity === undefined ? "" : ` fill-opacity="${path.fillOpacity}"`;
      return `<path d="${escapeAttribute(path.d)}" fill="${escapeAttribute(color)}"${opacity}/>`;
    })
    .join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="${escapeAttribute(definition.viewBox)}" preserveAspectRatio="xMidYMid meet">${paths}</svg>`;
}

export function GET(request: Request) {
  const url = new URL(request.url);
  const name = url.searchParams.get("name")?.trim();

  if (name) {
    const definition = getSymbolDefinition(name);
    if (!definition) return new Response("SF Symbol not found", { status: 404 });

    const svg = renderSymbolSvg(definition, safeColor(url.searchParams.get("color")));
    return new Response(svg, {
      headers: {
        "Cache-Control": "public, max-age=31536000, immutable",
        "Content-Type": "image/svg+xml; charset=utf-8",
      },
    });
  }

  const query = url.searchParams.get("q") ?? "";
  const requestedLimit = Number(url.searchParams.get("limit") ?? 40);
  const limit = Number.isFinite(requestedLimit)
    ? Math.max(1, Math.min(100, Math.trunc(requestedLimit)))
    : 40;

  return Response.json(
    { results: searchSymbols(query, limit) },
    { headers: { "Cache-Control": "public, max-age=86400" } },
  );
}
