#!/usr/bin/env bash
set -euo pipefail

# Called from build_wsl.sh's isolated Linux workspace after xtool assembles the app.
if ! command -v accord >/dev/null; then
  echo 'Missing accord. Run scripts/install_accord_wsl.sh in WSL first.' >&2
  exit 1
fi
seek_assets_output=.build/CompiledAssets
mkdir -p "$seek_assets_output"
accord --compile "$seek_assets_output" --platform iphoneos \
  --minimum-deployment-target 17.0 --xcode-version 27 \
  --app-icon AppIcon --accent-color AccentColor \
  --target-device iphone --target-device ipad \
  --output-partial-info-plist "$seek_assets_output/AppIcon-Info.plist" \
  SeekAPI/Resources/Assets.xcassets
accord inspect --json "$seek_assets_output/Assets.car" > "$seek_assets_output/catalog.json"
echo "Compiled native light/dark app icon catalog: $seek_assets_output/Assets.car"
