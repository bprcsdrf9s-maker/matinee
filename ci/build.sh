#!/bin/bash
# Builds an unsigned Matinee.ipa. AltStore/SideStore sign it with your Apple ID when installing.
set -euo pipefail

BUILD_NUMBER="${BUILD_NUMBER:-1}"
VERSION="1.0.${BUILD_NUMBER}"

# Use the newest Xcode on the machine (16 or later).
if [ -d /Applications ]; then
  XCODE=$(ls -d /Applications/Xcode_*.app /Applications/Xcode.app 2>/dev/null | grep -vi beta | sort -V | tail -1 || true)
  if [ -n "${XCODE:-}" ] && [ -n "${CI:-}" ]; then sudo xcode-select -s "$XCODE"; fi
fi
xcodebuild -version

command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

rm -rf build Payload Matinee.ipa
set +e
xcodebuild \
  -project Matinee.xcodeproj \
  -scheme Matinee \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build.log 2>&1
status=$?
set -e

if [ $status -ne 0 ]; then
  echo "Build failed. Errors:"
  grep -E "error:|fatal error" build.log | sort -u | head -60 || tail -80 build.log
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## Build failed"
      echo "Copy these lines and send them to Claude:"
      echo '```'
      grep -E "error:|fatal error" build.log | sed "s|$PWD/||" | sort -u | head -60
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
  exit $status
fi

APP=build/Build/Products/Release-iphoneos/Matinee.app
mkdir -p Payload
cp -R "$APP" Payload/
zip -qry Matinee.ipa Payload
rm -rf Payload
echo "Built Matinee.ipa ($VERSION, build $BUILD_NUMBER), $(du -h Matinee.ipa | cut -f1)"
