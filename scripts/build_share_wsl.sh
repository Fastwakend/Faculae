#!/usr/bin/env bash
set -euo pipefail
seek_share_sdk_root="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
seek_share_sdk="$seek_share_sdk_root/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
seek_share_runtime="$seek_share_sdk_root/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
seek_share_output=".build/SeekShare.appex"
mkdir -p "$seek_share_output"
swiftc -target arm64-apple-ios17.0 -sdk "$seek_share_sdk" \
  -resource-dir "$seek_share_runtime" -Xfrontend -enable-cross-import-overlays \
  -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -c -application-extension -module-name SeekShare \
  Packages/SeekCore/Sources/SeekCore/AttachmentFiles.swift \
  SeekAPI/Services/ShareInbox.swift SeekShare/ShareViewController.swift -o .build/SeekShare.o
"$seek_share_sdk_root/toolset/bin/ld64.lld" \
  -arch arm64 -platform_version ios 17.0 "$SEEK_IOS_SDK_VERSION" \
  -syslibroot "$seek_share_sdk" \
  -L "$seek_share_runtime/iphoneos" -L "$seek_share_sdk/usr/lib/swift" \
  -lSystem -lswiftCore -lobjc -framework Foundation -framework UIKit -application_extension \
  -e _NSExtensionMain -rpath /usr/lib/swift \
  -rpath '@executable_path/../../Frameworks' -rpath '@executable_path/Frameworks' \
  .build/SeekShare.o \
  "$seek_share_sdk_root/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/clang/21/lib/darwin/libclang_rt.ios.a" \
  -o "$seek_share_output/SeekShare"
python3 - "$seek_share_output" <<'PY'
from pathlib import Path
import os, plistlib, shutil, sys
out = Path(sys.argv[1])
info = plistlib.loads(Path('SeekShare/Info.plist').read_bytes())
app = plistlib.loads(Path('Config/Info-xtool.plist').read_bytes())
info.update(CFBundleExecutable='SeekShare', CFBundleIdentifier='app.seekapi.ios.share',
            CFBundleName='SeekShare', CFBundleVersion=app['CFBundleVersion'],
            CFBundleShortVersionString=app['CFBundleShortVersionString'],
            MinimumOSVersion='17.0', CFBundleSupportedPlatforms=['iPhoneOS'],
            UIDeviceFamily=[1, 2], DTPlatformName='iphoneos', DTSDKName='iphoneos'+os.environ['SEEK_IOS_SDK_VERSION'])
(out/'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
shutil.copyfile('Config/SeekShare.entitlements', out/'Signing.entitlements')
PY
echo "Built native Share extension: $seek_share_output"
