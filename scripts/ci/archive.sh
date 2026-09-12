#!/bin/bash
# archive.sh
#
# Archives the film-workflow app with the Developer ID identity into
# output/output.xcarchive. Shared by the release build and the PR signing
# check so both exercise the exact same xcodebuild invocation.
#
# Manual signing with a Developer ID identity. The profile is pinned to the
# app target's Release build settings in project.pbxproj
# (PROVISIONING_PROFILE_SPECIFIER), NOT passed on the command line: a
# command-line PROVISIONING_PROFILE* applies to every target in the graph —
# including the SPM package targets, which don't support provisioning profiles
# — and fails the archive. CODE_SIGN_STYLE and CODE_SIGN_IDENTITY stay global:
# the package targets sign with the identity but need no profile.
#
# Env:
#   SIGNING_CERTIFICATE_NAME  required
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
  CODE_SIGN_IDENTITY="${SIGNING_CERTIFICATE_NAME}" \
  CODE_SIGN_STYLE=Manual \
  OTHER_CODE_SIGN_FLAGS="--options=runtime --timestamp" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  archive 2>&1 | tee xcodebuild-archive.log | xcpretty || {
    status=${PIPESTATUS[0]}
    echo "::group::Full xcodebuild output (archive failed)"
    cat xcodebuild-archive.log
    echo "::endgroup::"
    exit "$status"
  }
