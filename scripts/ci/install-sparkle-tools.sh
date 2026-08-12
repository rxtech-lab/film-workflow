#!/bin/bash
# install-sparkle-tools.sh
#
# Downloads Sparkle's prebuilt distribution tools (generate_appcast, sign_update)
# into ./bin. Cached: re-running with the pinned version already present is a
# no-op, which keeps the self-hosted runner from re-downloading every build.
#
# Keep SPARKLE_VERSION in step with the Sparkle SPM dependency in
# film-workflow.xcodeproj — the appcast format is tied to the framework version
# that reads it.
set -euo pipefail

SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.5}"
BIN_DIR="${BIN_DIR:-bin}"
TOOL="$BIN_DIR/generate_appcast"

if [ -x "$TOOL" ] && [ "$(cat "$BIN_DIR/.sparkle-version" 2>/dev/null)" = "$SPARKLE_VERSION" ]; then
  echo "==> Sparkle tools $SPARKLE_VERSION already present at $BIN_DIR"
  exit 0
fi

echo "==> Downloading Sparkle $SPARKLE_VERSION tools"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
curl -fL --retry 3 --retry-delay 2 -o "$TMP_DIR/sparkle.tar.xz" "$URL"
tar -xJf "$TMP_DIR/sparkle.tar.xz" -C "$TMP_DIR"

mkdir -p "$BIN_DIR"
cp "$TMP_DIR/bin/generate_appcast" "$BIN_DIR/"
cp "$TMP_DIR/bin/sign_update" "$BIN_DIR/"
chmod +x "$BIN_DIR/generate_appcast" "$BIN_DIR/sign_update"
echo "$SPARKLE_VERSION" > "$BIN_DIR/.sparkle-version"

echo "==> Installed $("$TOOL" --version 2>/dev/null || echo "generate_appcast") to $BIN_DIR"
