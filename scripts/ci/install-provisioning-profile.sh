#!/bin/bash
# install-provisioning-profile.sh
#
# Installs the Developer ID provisioning profile from Actions secrets and
# publishes its UUID and team ID for the archive step.
#
# The app's com.apple.developer.associated-domains entitlement (passkey
# sign-in) is a restricted entitlement: codesign only accepts it when a
# provisioning profile authorising it is embedded in the bundle. The secret
# holds a base64 Developer ID profile for rxlab.film-workflow.
#
# Env:
#   MACOS_PROVISIONING_PROFILE_BASE64  required
#   PRODUCT_BUNDLE_ID                  default rxlab.film-workflow
set -e

PRODUCT_BUNDLE_ID="${PRODUCT_BUNDLE_ID:-rxlab.film-workflow}"

if [ -z "${MACOS_PROVISIONING_PROFILE_BASE64:-}" ]; then
  echo "::error::MACOS_PROVISIONING_PROFILE_BASE64 is required."
  exit 1
fi

TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/film-workflow-profile.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
PROFILE_PATH="$TMP_DIR/film-workflow.provisionprofile"
PROFILE_PLIST="$TMP_DIR/film-workflow-profile.plist"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

printf '%s' "$MACOS_PROVISIONING_PROFILE_BASE64" | base64 -D > "$PROFILE_PATH"
openssl cms -inform DER -verify -noverify -in "$PROFILE_PATH" -out "$PROFILE_PLIST"

PROFILE_UUID=$(/usr/libexec/PlistBuddy -c 'Print :UUID' "$PROFILE_PLIST")
PROFILE_NAME=$(/usr/libexec/PlistBuddy -c 'Print :Name' "$PROFILE_PLIST")
PROFILE_TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")

if ! [[ "$PROFILE_UUID" =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ &&
        "$PROFILE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "::error::The provisioning profile has an invalid UUID or team ID."
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

mkdir -p "$PROFILE_DIR"
cp "$PROFILE_PATH" "$PROFILE_DIR/$PROFILE_UUID.provisionprofile"
echo "Installed provisioning profile: $PROFILE_NAME ($PROFILE_UUID)"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'profile_uuid=%s\nteam_id=%s\n' "$PROFILE_UUID" "$PROFILE_TEAM_ID" >> "$GITHUB_OUTPUT"
fi
