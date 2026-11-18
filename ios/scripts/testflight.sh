#!/usr/bin/env bash
# Archive Workbook and upload it to App Store Connect for TestFlight, signed as Bird Street Exotics, LLC (team
# 96A2DBRK62). The build number is a UTC timestamp, so every upload is unique and newer than the last.
#   ios/scripts/testflight.sh
#
# Signing and upload use the Apple account signed into Xcode (Settings → Apple Accounts): Xcode creates the App Store
# provisioning profile itself and uploads the build (ExportOptions-TestFlight.plist). The app record in App Store
# Connect must use the bundle ID com.birdstreetexotics.workbook.app.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="${TMPDIR:-/tmp}/workbook-testflight"
build="$(date -u +%Y%m%d%H%M)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$here/.."
xcodegen generate >/dev/null
rm -rf "$out" && mkdir -p "$out"
echo "Archiving build ${build}…"
xcodebuild -project Workbook.xcodeproj -scheme Workbook -configuration Release \
  -destination "generic/platform=iOS" -archivePath "$out/Workbook.xcarchive" \
  -allowProvisioningUpdates CURRENT_PROJECT_VERSION="$build" archive -quiet
echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$out/Workbook.xcarchive" \
  -exportOptionsPlist "$here/ExportOptions-TestFlight.plist" -exportPath "$out/export" -allowProvisioningUpdates \
  | grep -E 'EXPORT|error|is complete' || true
echo "Uploaded build ${build}. It appears in TestFlight once App Store Connect finishes processing (a few minutes)."
