#!/bin/bash
# sign-sparkle.sh
#
# Signs the bundled compiler tools and Sparkle helpers with Developer ID and
# Hardened Runtime before re-sealing the archived app.
#
# Xcode signs Sparkle.framework with the identity used for the archive, but its
# nested helpers (Updater.app, Autoupdate, the XPC services) need to be signed
# individually with `--options runtime --timestamp` or notarization rejects
# them. Signing runs inside-out: helpers, then the framework, then the app.
#
set -e

APP_PATH="${APP_PATH:-output/output.xcarchive/Products/Applications/film-workflow.app}"
APP_BINARY_NAME="${APP_BINARY_NAME:-film-workflow}"

if [ -z "${SIGNING_CERTIFICATE_NAME}" ]; then
  echo "Error: SIGNING_CERTIFICATE_NAME is not set"
  exit 1
fi

if [ ! -d "$APP_PATH" ]; then
  echo "Error: $APP_PATH not found"
  exit 1
fi

SPARKLE_FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "Error: Sparkle.framework not embedded in $APP_PATH — the app cannot self-update"
  exit 1
fi

# The framework's current version directory is "B" today, but resolve it rather
# than hardcoding so a Sparkle bump doesn't silently skip the helper signing.
VERSION_DIR="$(readlink "$SPARKLE_FRAMEWORK/Versions/Current" 2>/dev/null || echo "B")"
SPARKLE_VERSIONED="$SPARKLE_FRAMEWORK/Versions/$VERSION_DIR"

sign() {
  local target="$1"
  if [ ! -e "$target" ]; then
    echo "Warning: $target not found, skipping"
    return
  fi
  codesign --force --options runtime --timestamp --sign "${SIGNING_CERTIFICATE_NAME}" "$target"
}

WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/film-workflow-sign.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

# The compiler extracts these npm archives to run esbuild and TypeScript.
# The app signature seals the archive files without signing their executables.
TOOLCHAINS_DIR="$APP_PATH/Contents/Resources/MotionSwift_MotionCompiler.bundle/Contents/Resources/Resources/Toolchains"

sign_compiler_archive() {
  local archive="$1"
  local executable="$2"
  local unpacked
  if [ ! -f "$archive" ]; then
    echo "Error: missing MotionSwift compiler archive: $archive" >&2
    exit 1
  fi
  unpacked="$(mktemp -d "$WORK_DIR/toolchain.XXXXXX")"
  tar -xzf "$archive" -C "$unpacked"
  if [ ! -x "$unpacked/$executable" ]; then
    echo "Error: $archive is missing executable $executable" >&2
    exit 1
  fi
  echo "Signing $executable in ${archive##*/}"
  sign "$unpacked/$executable"
  codesign --verify --strict "$unpacked/$executable"
  tar -czf "$WORK_DIR/${archive##*/}" -C "$unpacked" package
}

# Inside-out: the main framework binary, then the helpers it ships with.
sign "$SPARKLE_VERSIONED/Sparkle"
sign "$SPARKLE_VERSIONED/Updater.app"
sign "$SPARKLE_VERSIONED/Autoupdate"
sign "$SPARKLE_VERSIONED/XPCServices/Downloader.xpc"
sign "$SPARKLE_VERSIONED/XPCServices/Installer.xpc"

# Then the framework as a whole.
sign "$SPARKLE_FRAMEWORK"

# Capture the entitlements xcodebuild embedded in the archive BEFORE re-signing
# the app. `codesign --force` without --entitlements drops them, which would
# silently strip com.apple.developer.associated-domains and break passkey
# sign-in — codesign itself would not complain.
ENTITLEMENTS_PLIST="$WORK_DIR/archived-entitlements.plist"
codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH" 2>/dev/null

if [ ! -s "$ENTITLEMENTS_PLIST" ]; then
  echo "Error: failed to extract entitlements from the archived app; aborting rather than shipping an app with no entitlements"
  exit 1
fi

echo "Preserving archived entitlements:"
/usr/bin/plutil -p "$ENTITLEMENTS_PLIST" || true

for archive in "$TOOLCHAINS_DIR"/esbuild-darwin-*.tgz; do
  sign_compiler_archive "$archive" package/bin/esbuild
done
for archive in "$TOOLCHAINS_DIR"/typescript-typescript-darwin-*.tgz; do
  sign_compiler_archive "$archive" package/lib/tsc
done
mv -- "$WORK_DIR"/*.tgz "$TOOLCHAINS_DIR/"

codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" \
  --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/MacOS/$APP_BINARY_NAME"

codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" \
  --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH"

# Verify the resealed app carries exactly the entitlements the archive had.
# Diffing the whole plist (rather than grepping for a hardcoded key list)
# means the check tracks film-workflow.entitlements instead of drifting from
# it — the previous list still demanded the JIT entitlements the removed Bun
# runtime needed and failed every release after they were dropped.
RESEALED_PLIST="$WORK_DIR/resealed-entitlements.plist"
codesign -d --entitlements "$RESEALED_PLIST" --xml "$APP_PATH" 2>/dev/null

if ! diff <(/usr/bin/plutil -convert xml1 -o - "$ENTITLEMENTS_PLIST") \
          <(/usr/bin/plutil -convert xml1 -o - "$RESEALED_PLIST"); then
  echo "Error: entitlements changed after re-signing (archived vs resealed diff above)"
  exit 1
fi

# A bad nested signature only surfaces at notarization otherwise, minutes later.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Signing completed successfully"
