#!/bin/bash
# sign-sparkle.sh
#
# Re-signs the Sparkle framework and the app wrapper with the Developer ID
# identity and the Hardened Runtime.
#
# Xcode signs Sparkle.framework with the identity used for the archive, but its
# nested helpers (Updater.app, Autoupdate, the XPC services) need to be signed
# individually with `--options runtime --timestamp` or notarization rejects
# them. Signing runs inside-out: helpers, then the framework, then the app.
#
# The Remotion runtime binaries under Resources/RemotionRuntime are already
# signed by the "Sign Remotion Runtime" build phase; resealing the wrapper here
# (without --deep) leaves those signatures intact.
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
# strip the JIT / unsigned-executable-memory exceptions the embedded Bun runtime
# needs — the app would then crash the moment it renders anything.
ENTITLEMENTS_PLIST="${RUNNER_TEMP:-/tmp}/film-workflow.entitlements.plist"
codesign -d --entitlements "$ENTITLEMENTS_PLIST" --xml "$APP_PATH" 2>/dev/null

if [ ! -s "$ENTITLEMENTS_PLIST" ]; then
  echo "Error: failed to extract entitlements from the archived app; aborting rather than shipping an app that cannot run Bun"
  exit 1
fi

echo "Preserving archived entitlements:"
/usr/bin/plutil -p "$ENTITLEMENTS_PLIST" || true

codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" \
  --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH/Contents/MacOS/$APP_BINARY_NAME"

codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PLIST" \
  --sign "${SIGNING_CERTIFICATE_NAME}" "$APP_PATH"

# Verify the resealed app kept the entitlements Bun depends on.
RESEALED_ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null)"
for key in com.apple.security.cs.allow-jit com.apple.security.cs.disable-library-validation; do
  if ! printf '%s' "$RESEALED_ENTITLEMENTS" | grep -q "$key"; then
    echo "Error: $key entitlement missing after re-signing"
    exit 1
  fi
done

# A bad nested signature only surfaces at notarization otherwise, minutes later.
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Signing completed successfully"
