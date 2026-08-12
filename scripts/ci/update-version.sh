#!/bin/bash
# update-version.sh <version>
#
# Rewrites MARKETING_VERSION in project.pbxproj for the film-workflow app
# target only. CI calls this on release builds so the shipped app advertises the
# release tag (Sparkle compares CFBundleShortVersionString against the appcast).
set -e

VERSION="$1"

if [ -z "$VERSION" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.3"
  exit 1
fi

PROJECT_FILE="film-workflow.xcodeproj/project.pbxproj"
BUNDLE_IDENTIFIER="rxlab.film-workflow"

if [ ! -f "$PROJECT_FILE" ]; then
  echo "Error: $PROJECT_FILE not found"
  exit 1
fi

echo "Updating MARKETING_VERSION to $VERSION in $PROJECT_FILE for $BUNDLE_IDENTIFIER"

TMP_FILE=$(mktemp)

# Match whole buildSettings blocks rather than assuming MARKETING_VERSION sits
# next to PRODUCT_BUNDLE_IDENTIFIER. The test targets use a different bundle id,
# so they're left alone.
awk -v new_version="$VERSION" -v bundle_id="$BUNDLE_IDENTIFIER" '
BEGIN {
    in_build_settings = 0
    block = ""
    matched_bundle = 0
    updated_count = 0
}

/^[[:space:]]*buildSettings = \{[[:space:]]*$/ {
    in_build_settings = 1
    block = $0 ORS
    matched_bundle = 0
    next
}

in_build_settings {
    block = block $0 ORS
    if (index($0, "PRODUCT_BUNDLE_IDENTIFIER = \"" bundle_id "\";") > 0 ||
        index($0, "PRODUCT_BUNDLE_IDENTIFIER = " bundle_id ";") > 0) {
        matched_bundle = 1
    }
    if ($0 ~ /^[[:space:]]*\};[[:space:]]*$/) {
        if (matched_bundle) {
            updated_count += gsub(/MARKETING_VERSION = [^;]+;/, "MARKETING_VERSION = " new_version ";", block)
        }
        printf "%s", block
        in_build_settings = 0
        block = ""
        matched_bundle = 0
    }
    next
}

{ print }

END {
    if (in_build_settings) {
        printf "%s", block
    }
    if (updated_count == 0) {
        exit 1
    }
}
' "$PROJECT_FILE" > "$TMP_FILE"

mv "$TMP_FILE" "$PROJECT_FILE"

echo "Successfully updated MARKETING_VERSION to $VERSION"
