#!/bin/bash
# Publishes Matinee.ipa as a GitHub release, plus an AltStore source (source.json) that
# always points at the newest build: https://github.com/<you>/<repo>/releases/latest/download/source.json
set -euo pipefail

: "${REPO:?}" "${BUILD_NUMBER:?}"
VERSION="1.0.${BUILD_NUMBER}"
TAG="build-${BUILD_NUMBER}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
SIZE=$(stat -f%z Matinee.ipa 2>/dev/null || stat -c%s Matinee.ipa)
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

cp Matinee/Assets.xcassets/AppIcon.appiconset/icon-1024.png icon.png

cat > source.json <<JSON
{
  "name": "Watcher",
  "identifier": "com.daniel.matinee.source",
  "subtitle": "Your Stremio library, played natively.",
  "iconURL": "${BASE}/icon.png",
  "apps": [
    {
      "name": "Watcher",
      "bundleIdentifier": "com.daniel.matinee",
      "developerName": "Daniel",
      "subtitle": "Stremio on iPhone and iPad",
      "localizedDescription": "Sign in with your Stremio account to browse your addons' catalogs, your library and Continue Watching, and play streams in Apple's player or mpv.",
      "iconURL": "${BASE}/icon.png",
      "tintColor": "#F5B842",
      "category": "entertainment",
      "versions": [
        {
          "version": "${VERSION}",
          "buildVersion": "${BUILD_NUMBER}",
          "date": "${DATE}",
          "size": ${SIZE},
          "downloadURL": "${BASE}/Matinee.ipa",
          "minOSVersion": "18.0"
        }
      ],
      "appPermissions": {
        "entitlements": [],
        "privacy": {}
      }
    }
  ],
  "news": []
}
JSON

NOTES="Build ${BUILD_NUMBER}. Install through AltStore or SideStore with the source link: https://github.com/${REPO}/releases/latest/download/source.json"
ASSETS=(Matinee.ipa source.json icon.png)
if [ -f Matinee-AppleTV-Xcode.zip ]; then
  ASSETS+=(Matinee-AppleTV-Xcode.zip)
  NOTES="${NOTES}

Apple TV: download Matinee-AppleTV-Xcode.zip, open Matinee.xcodeproj on a Mac and run the MatineeTV scheme on your Apple TV (steps in README-Apple-TV.txt)."
elif [ -f tvos-errors.txt ]; then
  NOTES="${NOTES}

Apple TV build failed:
\`\`\`
$(head -60 tvos-errors.txt)
\`\`\`"
fi

gh release create "$TAG" "${ASSETS[@]}" \
  --repo "$REPO" \
  --title "Watcher ${VERSION}" \
  --notes "$NOTES" \
  --latest

{
  echo "## Watcher ${VERSION} is ready"
  echo ""
  echo "Add this source in AltStore or SideStore:"
  echo ""
  echo "https://github.com/${REPO}/releases/latest/download/source.json"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"
