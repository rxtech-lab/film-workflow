#!/usr/bin/env bash
# sign-remotion-runtime.sh
#
# Re-signs every Mach-O binary embedded under Resources/RemotionRuntime with the
# Hardened Runtime enabled.
#
# RemotionRuntime is copied into the app as a plain folder reference, so Xcode
# only signs the app wrapper — the binaries inside (bun, esbuild, ffmpeg,
# ffprobe, the Remotion compositor and its dylibs) keep the ad-hoc,
# linker-signed signatures they shipped with. Notarization/App Store upload then
# rejects the archive with:
#
#   "esbuild", "ffmpeg", "ffprobe", "remotion" ... must be rebuilt with support
#   for the Hardened Runtime.
#
# This runs as a build phase after "Copy Bundle Resources"; Xcode signs the app
# wrapper afterwards and seals these signatures in.
#
# Usage (build phase):
#   bash "$SRCROOT/scripts/sign-remotion-runtime.sh"

set -euo pipefail

if [[ "${PLATFORM_NAME:-macosx}" != "macosx" ]]; then
  echo "==> Skipping Remotion runtime signing on ${PLATFORM_NAME:-unknown}"
  exit 0
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" != "YES" ]]; then
  echo "==> CODE_SIGNING_ALLOWED=NO, skipping Remotion runtime signing"
  exit 0
fi

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [[ -z "$IDENTITY" || "$IDENTITY" == "-" ]]; then
  echo "==> No signing identity, skipping Remotion runtime signing"
  exit 0
fi

RUNTIME_DIR="${TARGET_BUILD_DIR:?}/${UNLOCALIZED_RESOURCES_FOLDER_PATH:?}/RemotionRuntime"
if [[ ! -d "$RUNTIME_DIR" ]]; then
  echo "==> $RUNTIME_DIR not found, nothing to sign"
  exit 0
fi

ENTITLEMENTS="${SRCROOT:?}/film-workflow/RemotionRuntime.entitlements"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "error: missing $ENTITLEMENTS" >&2
  exit 1
fi

# Timestamping needs the network and is only required for distribution.
timestamp_flag="--timestamp"
if [[ "${CONFIGURATION:-Release}" == "Debug" ]]; then
  timestamp_flag="--timestamp=none"
fi

is_macho() {
  local magic
  magic="$(od -An -tx1 -N4 "$1" 2>/dev/null | tr -d ' \n')" || return 1
  case "$magic" in
    # thin (LE/BE, 32/64-bit) and fat/universal magics
    cffaedfe | cefaedfe | feedfacf | feedface | cafebabe | bebafeca) return 0 ;;
    *) return 1 ;;
  esac
}

signed=0
skipped=0

# Executables carry the entitlements; libraries are signed without them (Apple
# ignores entitlements on non-executable Mach-O and codesign warns about them).
while IFS= read -r -d '' file; do
  is_macho "$file" || { skipped=$((skipped + 1)); continue; }

  case "$file" in
    *.dylib | *.so | *.node)
      codesign --force --sign "$IDENTITY" --options runtime "$timestamp_flag" "$file"
      ;;
    *)
      codesign --force --sign "$IDENTITY" --options runtime \
        --entitlements "$ENTITLEMENTS" "$timestamp_flag" "$file"
      ;;
  esac
  signed=$((signed + 1))
done < <(
  find "$RUNTIME_DIR" -type f \
    \( -perm +111 -o -name '*.dylib' -o -name '*.so' -o -name '*.node' \) \
    -print0
)

echo "==> Signed $signed embedded binaries with the Hardened Runtime ($skipped non-Mach-O skipped)"
