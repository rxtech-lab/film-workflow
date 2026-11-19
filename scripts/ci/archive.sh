#!/bin/bash
# archive.sh
#
# Archives the film-workflow app with the Developer ID identity into
# output/output.xcarchive. Shared by the release build and the PR signing
# check so both exercise the exact same xcodebuild invocation.
#
# Release.xcconfig uses SIGNING_PROFILE_UUID to select the profile for the
# app target. Setting PROVISIONING_PROFILE_SPECIFIER on the command line
# would also apply it to Swift package targets, which don't support profiles.
#
# Env:
#   SIGNING_CERTIFICATE_NAME  required
#   SIGNING_PROFILE_UUID      provisioned app profile, from the install step
#   SIGNING_TEAM_ID           team ID from that profile
#   BUILD_NUMBER              CURRENT_PROJECT_VERSION override so every release
#                             has a unique build number (github.run_number)
#                             without committing churn to project.pbxproj.
#                             Sparkle uses it as the update ordering key.
#   ARCHIVE_PATH              default output/output.xcarchive
set -e

ARCHIVE_PATH="${ARCHIVE_PATH:-output/output.xcarchive}"

if [ -z "${SIGNING_CERTIFICATE_NAME}" ]; then
  echo "Error: SIGNING_CERTIFICATE_NAME is not set"
  exit 1
fi

if [ -z "${SIGNING_PROFILE_UUID}" ] || [ -z "${SIGNING_TEAM_ID}" ]; then
  echo "Error: SIGNING_PROFILE_UUID and SIGNING_TEAM_ID are required from the profile install step" >&2
  exit 1
fi

if [ -z "${BUILD_NUMBER}" ]; then
  echo "Error: BUILD_NUMBER is not set"
  exit 1
fi

command -v xcpretty >/dev/null 2>&1 || gem install xcpretty

set -o pipefail
xcodebuild -destination platform=macOS \
  -project film-workflow.xcodeproj \
  -scheme film-workflow \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  ARCHS=arm64 \
  CODE_SIGN_IDENTITY="${SIGNING_CERTIFICATE_NAME}" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="${SIGNING_TEAM_ID}" \
  SIGNING_PROFILE_UUID="${SIGNING_PROFILE_UUID}" \
  OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  archive 2>&1 | tee xcodebuild-archive.log | xcpretty || {
    status=${PIPESTATUS[0]}
    echo "::group::Full xcodebuild output (archive failed)"
    cat xcodebuild-archive.log
    echo "::endgroup::"
    exit "$status"
  }
