#!/bin/bash
# notary.sh
#
# Packages the archived app into a DMG, submits it to Apple's notary service and
# staples the ticket so the download opens without a Gatekeeper prompt.
#
# Requires APPLE_ID / APPLE_ID_PWD (an app-specific password) / APPLE_TEAM_ID.
set -e

APP_NAME="${APP_NAME:-./output/output.xcarchive/Products/Applications/film-workflow.app}"
DMG_NAME="${DMG_NAME:-RxFilmStudio.dmg}"

if [ -f "$DMG_NAME" ]; then
  echo "Removing existing DMG file"
  rm "$DMG_NAME"
fi

# create-dmg names the output after the app and its version; rename it to the
# stable asset name the appcast's download URL is built from.
create-dmg --overwrite "$APP_NAME"
mv -- ./*.dmg "$DMG_NAME"

if [ ! -f "$DMG_NAME" ]; then
  echo "Error: create-dmg produced no disk image"
  exit 1
fi

echo "DMG created: $DMG_NAME"

xcrun notarytool submit "./$DMG_NAME" --verbose \
  --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" \
  --password "$APPLE_ID_PWD" \
  --wait

xcrun stapler staple "$DMG_NAME"

echo "All operations completed successfully!"
