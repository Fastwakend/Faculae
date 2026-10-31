#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This verification requires macOS with Xcode 26 or later."
  exit 1
fi
xcode_major=$(xcodebuild -version | awk '/^Xcode / { split($2, version, "."); print version[1] }')
if [[ -z "$xcode_major" || "$xcode_major" -lt 26 ]]; then
  echo "Xcode 26 or later is required for Liquid Glass. Select it with DEVELOPER_DIR or xcode-select."
  exit 1
fi
swift test --package-path Packages/SeekCore
xcodebuild -resolvePackageDependencies -project SeekAPI.xcodeproj -scheme SeekAPI
xcodebuild -project SeekAPI.xcodeproj -scheme SeekAPI -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build
echo "Core tests and unsigned iOS Simulator build passed."
