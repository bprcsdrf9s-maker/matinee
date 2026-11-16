#!/bin/bash
# Build Matinee.ipa on your own Mac (needs Xcode 16+). Installs XcodeGen with Homebrew if needed.
set -euo pipefail
cd "$(dirname "$0")"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%y%m%d%H%M)}" bash ci/build.sh
echo "Done: $(pwd)/Matinee.ipa"
