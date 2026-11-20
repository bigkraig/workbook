#!/usr/bin/env bash
# Archive Workbook and upload it to App Store Connect for TestFlight, signed as Bird Street Exotics, LLC (team
# 96A2DBRK62). The build number is a UTC timestamp, so every upload is unique and newer than the last.
#   ios/scripts/testflight.sh
#
# Authentication, either of:
# - An App Store Connect API key (no Xcode sign-in needed): set ASC_KEY_ID and ASC_ISSUER_ID, in the environment or in
#   ~/.config/workbook/asc.env, with the .p8 at ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 (or
#   ASC_KEY_PATH). The .ipa is then signed locally with the Apple Distribution certificate in the login keychain and a
#   manually managed App Store profile named "Workbook BSE App Store" for com.birdstreetexotics.workbook.app
#   (ExportOptions-Export.plist), and uploaded with Apple's transporter.
# - Otherwise the Apple account signed into Xcode (Settings → Apple Accounts): Xcode creates the App Store profile
#   itself and uploads the build (ExportOptions-TestFlight.plist).
# The app record in App Store Connect must use the bundle ID com.birdstreetexotics.workbook.app.
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
[[ -f "$HOME/.config/workbook/asc.env" ]] && source "$HOME/.config/workbook/asc.env"
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  [[ -f "$key" ]] || { echo "App Store Connect key not found at $key" >&2; exit 1; }
  echo "Exporting a signed .ipa…"
  xcodebuild -exportArchive -archivePath "$out/Workbook.xcarchive" \
    -exportOptionsPlist "$here/ExportOptions-Export.plist" -exportPath "$out/ipa" -quiet
  echo "Uploading to App Store Connect with API key ${ASC_KEY_ID}…"
  xcrun altool --upload-app --type ios -f "$out/ipa/Workbook.ipa" --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" \
    2>&1 | tee "$out/export.log" | grep -E 'UPLOAD|error|Delivery UUID' || true
  grep -q 'UPLOAD SUCCEEDED' "$out/export.log" || { echo "Upload FAILED for build ${build}; see $out/export.log" >&2; exit 1; }
else
  echo "Uploading to App Store Connect with the Apple account signed into Xcode…"
  xcodebuild -exportArchive -archivePath "$out/Workbook.xcarchive" \
    -exportOptionsPlist "$here/ExportOptions-TestFlight.plist" -exportPath "$out/export" -allowProvisioningUpdates \
    2>&1 | tee "$out/export.log" | grep -E 'EXPORT|error|is complete' || true
  grep -q 'EXPORT SUCCEEDED' "$out/export.log" || { echo "Upload FAILED for build ${build}; see $out/export.log" >&2; exit 1; }
fi
echo "Uploaded build ${build}. It appears in TestFlight once App Store Connect finishes processing (a few minutes)."
