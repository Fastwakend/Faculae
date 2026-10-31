#!/usr/bin/env bash
set -euo pipefail

# Sources remain on Windows; build products and caches stay on WSL's Linux disk.
seek_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
seek_build="${XDG_CACHE_HOME:-$HOME/.cache}/seekapi-build/workspace"
seek_artifacts="$seek_source/artifacts"
seek_mode="${1:-build}"
if [[ "$seek_mode" != build && "$seek_mode" != test ]]; then
  echo "Usage: bash scripts/build_wsl.sh [build|test]" >&2
  exit 1
fi
if [[ -f "$HOME/.local/share/swiftly/env.sh" ]]; then
  . "$HOME/.local/share/swiftly/env.sh"
fi
export PATH="$HOME/.local/bin:$PATH"
command -v swift >/dev/null
command -v rsync >/dev/null
if [[ "$seek_mode" == build ]] && ! command -v accord >/dev/null; then
  echo 'Missing accord. Run scripts/install_accord_wsl.sh in WSL first.' >&2
  exit 1
fi
mkdir -p "$seek_build" "$seek_artifacts"
seek_build="$(realpath "$seek_build")"
if [[ "$seek_build" == / || "$seek_build" == "$seek_source" || "$seek_build" == /mnt/* ]]; then
  echo "Build directory must be a separate WSL Linux directory." >&2
  exit 1
fi
# --delete applies only to the three explicitly named, disposable source copies.
for seek_dir in SeekAPI SeekActivity SeekShare Packages Config; do
  mkdir -p "$seek_build/$seek_dir"
  rsync -a --delete --exclude=.build --exclude=Signing.xcconfig \
    "$seek_source/$seek_dir/" "$seek_build/$seek_dir/"
done
cp "$seek_source/Package.swift" "$seek_source/xtool.yml" "$seek_build/"
cd "$seek_build"
swift --version
swift test --package-path Packages/SeekCore --jobs 2 2>&1 | tee "$seek_artifacts/core-tests-wsl.log"
swiftc -parse-as-library Packages/SeekCore/Sources/SeekCore/AttachmentFiles.swift SeekAPI/Services/ShareInbox.swift "$seek_source/tools/tests/ShareInboxTests.swift" -o .build/share-inbox-tests
.build/share-inbox-tests 2>&1 | tee "$seek_artifacts/share-inbox-tests.log"
if [[ "$seek_mode" == test ]]; then exit 0; fi
xtool --version
xtool sdk status
# Preserve the real SDK version in LC_BUILD_VERSION. Swift Build on Linux can
# otherwise pass 17.0 (the deployment target) as both the minimum and SDK version.
seek_sdk_settings="${SEEK_IOS_SDK_SETTINGS:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/SDKSettings.json}"
seek_sdk_version="$(python3 - "$seek_sdk_settings" "$seek_artifacts/ios-sdk-build.json" <<'PY'
import json, re, sys
from pathlib import Path
settings = Path(sys.argv[1])
sdk = json.loads(settings.read_text())
version = sdk["Version"]
assert re.fullmatch(r"\d+\.\d+(\.\d+)?", version), "Invalid Apple SDK version"
assert int(version.split('.')[0]) >= 26, "Liquid Glass requires iOS SDK 26 or newer"
Path(sys.argv[2]).write_text(json.dumps({"sdk_version": version, "canonical_name": sdk["CanonicalName"], "settings_path": str(settings), "deployment_target": "17.0"}, indent=2) + "\n")
print(version)
PY
)"
export SEEK_IOS_SDK_VERSION="$seek_sdk_version"
echo "Linking against iOS SDK $SEEK_IOS_SDK_VERSION (minimum iOS 17.0)"
# Signing is a separate step; no Apple account is needed to compile this IPA.
xtool dev build --ipa --configuration release 2>&1 | tee "$seek_artifacts/ios-build-wsl.log"
bash "$seek_source/scripts/build_assets_wsl.sh" 2>&1 | tee "$seek_artifacts/asset-build-wsl.log"
python3 "$seek_source/tools/embed_assets.py" xtool/SeekAPI.ipa .build/CompiledAssets
cp .build/CompiledAssets/catalog.json "$seek_artifacts/asset-catalog.json"
cp .build/CompiledAssets/Assets.car "$seek_artifacts/Faculae-Assets.car"
cp .build/CompiledAssets/AppIcon-Info.plist "$seek_artifacts/Faculae-AppIcon-Info.plist"
bash "$seek_source/scripts/build_activity_wsl.sh" 2>&1 | tee "$seek_artifacts/activity-build-wsl.log"
python3 "$seek_source/tools/embed_activity.py" xtool/SeekAPI.ipa .build/SeekActivity.appex
bash "$seek_source/scripts/build_share_wsl.sh" 2>&1 | tee "$seek_artifacts/share-build-wsl.log"
python3 "$seek_source/tools/embed_activity.py" xtool/SeekAPI.ipa .build/SeekShare.appex
test -f xtool/SeekAPI.ipa
cp xtool/SeekAPI.ipa "$seek_artifacts/SeekAPI-unsigned.ipa"
python3 "$seek_source/tools/verify_release.py"
(cd "$seek_artifacts" && sha256sum SeekAPI-unsigned.ipa) | tee "$seek_artifacts/SeekAPI-unsigned.sha256"
cp "$seek_artifacts/SeekAPI-unsigned.ipa" "$seek_artifacts/Faculae-unsigned.ipa"
(cd "$seek_artifacts" && sha256sum Faculae-unsigned.ipa) > "$seek_artifacts/Faculae-unsigned.sha256"
echo "IPA: $seek_artifacts/Faculae-unsigned.ipa"
