#!/bin/bash
# generate-appcast.sh
#
# Builds the Sparkle appcast for the DMG sitting in the working directory and
# signs it with the EdDSA private key from the SPARKLE_KEY secret. The result is
# published to GitHub Pages (update.filmstudio.rxlab.app) by the release workflow; the
# DMG itself is served from the GitHub release, which is why the download URL
# prefix is rewritten here.
#
# Every check below is a guard against shipping an appcast the app will silently
# refuse: an unsigned item never installs, and a wrong download prefix 404s.
set -euo pipefail

: "${SPARKLE_KEY:?SPARKLE_KEY is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"

RELEASES_URL="https://github.com/rxtech-lab/film-workflow/releases"
DOWNLOAD_URL_PREFIX="${RELEASES_URL}/download/${VERSION}/"
EXPECTED_MINIMUM_SYSTEM_VERSION="${EXPECTED_MINIMUM_SYSTEM_VERSION:-26.2}"

./scripts/ci/install-sparkle-tools.sh

# generate_appcast reads the key from a file, not the environment.
KEY_FILE="$(mktemp)"
trap 'rm -f "$KEY_FILE"' EXIT
printf '%s' "$SPARKLE_KEY" > "$KEY_FILE"

echo "Generating appcast for version: $VERSION"

if [ -n "${RELEASE_NOTE:-}" ]; then
  echo "$RELEASE_NOTE" > release_notes.md
  python3 scripts/ci/convert-markdown.py release_notes.md release_notes.html
else
  echo "No release notes provided"
fi

./bin/generate_appcast ./ \
  --ed-key-file "$KEY_FILE" \
  --link "$RELEASES_URL" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX"

if ! grep -Fq "$DOWNLOAD_URL_PREFIX" appcast.xml; then
  echo "Error: generated appcast does not contain the expected download URL prefix"
  exit 1
fi

if ! grep -Fq "sparkle:edSignature=" appcast.xml; then
  echo "Error: generated appcast is missing sparkle:edSignature"
  exit 1
fi

if ! grep -Fq "<sparkle:minimumSystemVersion>${EXPECTED_MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>" appcast.xml; then
  echo "Error: generated appcast does not advertise macOS ${EXPECTED_MINIMUM_SYSTEM_VERSION} as the minimum system version"
  exit 1
fi

if [ -f "release_notes.html" ]; then
  python3 scripts/ci/update-xml.py appcast.xml release_notes.html "$BUILD_NUMBER"
fi

# The post-processing step rewrites the XML tree, so re-assert the invariants.
if ! grep -Fq "sparkle:edSignature=" appcast.xml; then
  echo "Error: appcast post-processing removed sparkle:edSignature"
  exit 1
fi

if ! grep -Fq "<sparkle:minimumSystemVersion>${EXPECTED_MINIMUM_SYSTEM_VERSION}</sparkle:minimumSystemVersion>" appcast.xml; then
  echo "Error: appcast post-processing changed the minimum system version"
  exit 1
fi

echo "Appcast generated:"
cat appcast.xml
