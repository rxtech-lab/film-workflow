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
NOTARY_AUTH=(
  --apple-id "${APPLE_ID:?Missing notarization Apple ID}"
  --team-id "${APPLE_TEAM_ID:?Missing notarization team ID}"
  --password "${APPLE_ID_PWD:?Missing notarization app-specific password}"
)

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

# notarytool can return zero after Apple marks a submission Invalid.
submit_exit=0
result="$(xcrun notarytool submit "./$DMG_NAME" "${NOTARY_AUTH[@]}" \
  --wait --output-format json)" || submit_exit=$?
printf '%s\n' "$result"
status="$(/usr/bin/plutil -extract status raw -expect string -o - - <<< "$result" 2>/dev/null)" || status=Unknown

if [ "$submit_exit" -ne 0 ] || [ "$status" != "Accepted" ]; then
  echo "Error: DMG notarization ended with status $status (notarytool exit $submit_exit)" >&2
  if submission_id="$(/usr/bin/plutil -extract id raw -expect string -o - - <<< "$result" 2>/dev/null)" &&
      [ -n "$submission_id" ]; then
    xcrun notarytool log "$submission_id" "${NOTARY_AUTH[@]}" ||
      echo "Error: could not fetch Apple notarization log for $submission_id" >&2
  fi
  exit "$((submit_exit == 0 ? 1 : submit_exit))"
fi

xcrun stapler staple "$DMG_NAME"

echo "All operations completed successfully!"
