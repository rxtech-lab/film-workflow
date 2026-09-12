#!/bin/bash
# install-provisioning-profile.sh
#
# Decodes MACOS_PROVISIONING_PROFILE_BASE64 into ~/Library/MobileDevice/
# Provisioning Profiles and sanity-checks it against what project.pbxproj
# expects, so a mismatch fails here rather than minutes into the archive.
#
# The app's com.apple.developer.associated-domains entitlement (passkey
# sign-in) is a restricted entitlement: codesign only accepts it when a
# provisioning profile authorising it is embedded in the bundle. The secret
# holds a base64 Developer ID profile for rxlab.film-workflow.
#
# Env:
#   MACOS_PROVISIONING_PROFILE_BASE64  required
#   EXPECTED_PROFILE_NAME              must match PROVISIONING_PROFILE_SPECIFIER
#                                      [sdk=macosx*] on the film-workflow
#                                      target's Release config (default FilmStudio)
#   PRODUCT_BUNDLE_ID                  default rxlab.film-workflow
set -e

EXPECTED_PROFILE_NAME="${EXPECTED_PROFILE_NAME:-FilmStudio}"
PRODUCT_BUNDLE_ID="${PRODUCT_BUNDLE_ID:-rxlab.film-workflow}"
TMP_DIR="${RUNNER_TEMP:-/tmp}"

if [ -z "$MACOS_PROVISIONING_PROFILE_BASE64" ]; then
  echo "::error::MACOS_PROVISIONING_PROFILE_BASE64 is required."
  exit 1
fi

PROFILE_PATH="$TMP_DIR/film-workflow.provisionprofile"
PROFILE_PLIST="$TMP_DIR/film-workflow-profile.plist"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

mkdir -p "$PROFILE_DIR"
printf '%s' "$MACOS_PROVISIONING_PROFILE_BASE64" | base64 -D > "$PROFILE_PATH"
openssl cms -inform DER -verify -noverify -in "$PROFILE_PATH" -out "$PROFILE_PLIST"

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c "Print UUID" "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c "Print Name" "$PROFILE_PLIST")

cp "$PROFILE_PATH" "$PROFILE_DIR/$PROFILE_UUID.provisionprofile"
echo "Installed provisioning profile: $PROFILE_NAME ($PROFILE_UUID)"

# xcodebuild matches the profile by name, so the secret's profile and
# PROVISIONING_PROFILE_SPECIFIER in project.pbxproj must agree. Fail here with
# the actual name rather than 200 lines into the archive log.
if [ "$PROFILE_NAME" != "$EXPECTED_PROFILE_NAME" ]; then
  echo "::error::Profile is named '$PROFILE_NAME' but project.pbxproj pins PROVISIONING_PROFILE_SPECIFIER to '$EXPECTED_PROFILE_NAME'. Update one to match the other."
  exit 1
fi

# The profile has to cover this bundle id and carry the restricted
# entitlement, otherwise codesign rejects the app at the end of a
# multi-minute archive.
PROFILE_APP_ID=$(/usr/libexec/PlistBuddy -c "Print Entitlements:com.apple.application-identifier" "$PROFILE_PLIST" 2>/dev/null || true)
if [ "${PROFILE_APP_ID#*.}" != "$PRODUCT_BUNDLE_ID" ]; then
  echo "::error::Profile covers '${PROFILE_APP_ID:-<none>}', not '$PRODUCT_BUNDLE_ID'."
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c "Print Entitlements:com.apple.developer.associated-domains" "$PROFILE_PLIST" >/dev/null 2>&1; then
  echo "::error::Profile lacks com.apple.developer.associated-domains. Enable Associated Domains on the App ID, then regenerate the profile."
  exit 1
fi

# Developer ID profiles provision all devices; a Development or App Store
# profile here would not match the Developer ID signing identity.
if ! /usr/libexec/PlistBuddy -c "Print ProvisionsAllDevices" "$PROFILE_PLIST" >/dev/null 2>&1; then
  echo "::warning::Profile does not look like a Developer ID profile (no ProvisionsAllDevices)."
fi
