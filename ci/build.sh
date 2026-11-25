#!/bin/bash
# Builds an unsigned Watcher.ipa. AltStore/SideStore sign it with your Apple ID when installing.
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

# The Apple TV icon and Top Shelf art are drawn here rather than stored in the repo.
if [ ! -f "MatineeTV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/Contents.json" ]; then
  python3 -m venv /tmp/iconenv && /tmp/iconenv/bin/pip install -q pillow     && /tmp/iconenv/bin/python ci/make-tv-icons.py MatineeTV/Assets.xcassets     || echo "::warning::Couldn't draw the Apple TV icons"
fi
xcodegen generate

rm -rf build Payload Watcher.ipa
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
zip -qry Watcher.ipa Payload
rm -rf Payload
echo "Built Watcher.ipa ($VERSION, build $BUILD_NUMBER), $(du -h Watcher.ipa | cut -f1)"

# Apple TV: compile to check it builds, then package a ready-to-open Xcode project for installing
# from a Mac (Xcode signs it with your Apple ID). A failure here doesn't stop the iPhone release.
rm -f Watcher-AppleTV-Xcode.zip tvos-errors.txt
set +e
xcodebuild \
  -project Matinee.xcodeproj \
  -scheme MatineeTV \
  -configuration Release \
  -sdk appletvos \
  -destination 'generic/platform=tvOS' \
  -derivedDataPath build \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build-tvos.log 2>&1
tv_status=$?
set -e

if [ $tv_status -ne 0 ]; then
  echo "Apple TV build failed. Errors:"
  grep -E "error:|fatal error" build-tvos.log | sed "s|$PWD/||" | sort -u | head -80 | tee tvos-errors.txt
  [ -s tvos-errors.txt ] || tail -60 build-tvos.log > tvos-errors.txt
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    { echo "## Apple TV build failed"; echo '```'; cat tvos-errors.txt; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
  fi
else
  # Bake this build's version into the project so Xcode on the Mac shows the same number.
  sed -i '' "s/MARKETING_VERSION: \"1.0\"/MARKETING_VERSION: \"$VERSION\"/; s/CURRENT_PROJECT_VERSION: \"1\"/CURRENT_PROJECT_VERSION: \"$BUILD_NUMBER\"/" project.yml
  xcodegen generate
  rm -rf pkg && mkdir -p pkg/Watcher
  cp -R project.yml Matinee.xcodeproj Matinee MatineeTV pkg/Watcher/
  cp ci/AppleTV-README.txt pkg/Watcher/README-Apple-TV.txt
  (cd pkg && zip -qry ../Watcher-AppleTV-Xcode.zip Watcher)
  rm -rf pkg
  git checkout -- project.yml 2>/dev/null || true
  echo "Built the Apple TV app and packaged Watcher-AppleTV-Xcode.zip ($(du -h Watcher-AppleTV-Xcode.zip | cut -f1))"
fi
