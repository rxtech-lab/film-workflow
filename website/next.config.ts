import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  serverExternalPackages: ["@bradleyhodges/sfsymbols"],
  outputFileTracingIncludes: {
    // The SVG route loads individual symbol modules by name at runtime.
    "/api/sf-symbols": [
      "./node_modules/@bradleyhodges/sfsymbols/package.json",
      "./node_modules/@bradleyhodges/sfsymbols/dist/main/*.js",
    ],
  },
};

export default nextConfig;
