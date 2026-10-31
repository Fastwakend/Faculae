#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This verification requires macOS with Xcode 15 or later."
  exit 1
fi
swift test --package-path Packages/SeekCore
xcodebuild -resolvePackageDependencies -project SeekAPI.xcodeproj -scheme SeekAPI
xcodebuild -project SeekAPI.xcodeproj -scheme SeekAPI -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
echo "Core tests and unsigned iOS Simulator build passed."
