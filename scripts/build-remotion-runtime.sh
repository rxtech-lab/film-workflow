#!/usr/bin/env bash
# build-remotion-runtime.sh
#
# Bootstraps the embedded Remotion runtime that ships inside film-workflow.app.
# Idempotent: re-running this script with all artifacts already present is a no-op.
#
# Outputs:
#   RemotionRuntime/bun                       — universal macOS Bun binary
#   RemotionRuntime/template/node_modules/    — pre-installed Remotion deps
#
# Usage:
#   bash scripts/build-remotion-runtime.sh
#
# Run from the repo root, or set RUNTIME_DIR to override.

set -euo pipefail

if [[ "${SKIP_REMOTION_RUNTIME_BUILD:-0}" == "1" ]]; then
  echo "==> SKIP_REMOTION_RUNTIME_BUILD=1, skipping"
  exit 0
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_DIR="${RUNTIME_DIR:-$REPO_ROOT/RemotionRuntime}"
TEMPLATE_DIR="$RUNTIME_DIR/template"
BUN_PATH="$RUNTIME_DIR/bun"

# Pinned for reproducibility; bump as needed.
BUN_VERSION="${BUN_VERSION:-1.2.21}"

arch="$(uname -m)"
case "$arch" in
  arm64) BUN_TARGET="darwin-aarch64" ;;
  x86_64) BUN_TARGET="darwin-x64" ;;
  *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
esac

mkdir -p "$RUNTIME_DIR"

# 1. Download Bun if missing or wrong version.
need_bun=1
if [[ -x "$BUN_PATH" ]]; then
  current="$("$BUN_PATH" --version 2>/dev/null || true)"
  if [[ "$current" == "$BUN_VERSION" ]]; then
    need_bun=0
  fi
fi

if [[ "$need_bun" == "1" ]]; then
  echo "==> Downloading Bun $BUN_VERSION ($BUN_TARGET)"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}/bun-${BUN_TARGET}.zip"
  curl -fL --retry 3 --retry-delay 2 -o "$tmp/bun.zip" "$url"
  unzip -q "$tmp/bun.zip" -d "$tmp"
  mv "$tmp/bun-${BUN_TARGET}/bun" "$BUN_PATH"
  chmod +x "$BUN_PATH"
fi

echo "==> Bun: $("$BUN_PATH" --version)"

# 2. Install template node_modules.
if [[ ! -d "$TEMPLATE_DIR/node_modules" ]]; then
  echo "==> Installing Remotion dependencies in template/"
  (cd "$TEMPLATE_DIR" && "$BUN_PATH" install)
else
  echo "==> template/node_modules already present (skipping bun install — delete to refresh)"
fi

echo "==> Remotion runtime ready at $RUNTIME_DIR"
