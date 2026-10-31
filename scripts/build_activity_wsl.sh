#!/usr/bin/env bash
set -euo pipefail
# Called by build_wsl.sh from its isolated Linux build workspace.
seek_activity_sdk_root="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
seek_activity_sdk="$seek_activity_sdk_root/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk"
seek_activity_runtime="$seek_activity_sdk_root/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift"
seek_activity_output=".build/SeekActivity.appex"
mkdir -p "$seek_activity_output"
swiftc -target arm64-apple-ios17.0 -sdk "$seek_activity_sdk" \
  -resource-dir "$seek_activity_runtime" \
  -Xfrontend -enable-cross-import-overlays \
  -swift-version 5 -O -whole-module-optimization -parse-as-library \
  -c -application-extension -module-name SeekActivity \
  SeekAPI/Services/ReplyActivityAttributes.swift SeekActivity/SeekReplyWidget.swift \
  -o .build/SeekActivity.o
"$seek_activity_sdk_root/toolset/bin/ld64.lld" \
  -arch arm64 -platform_version ios 17.0 "$SEEK_IOS_SDK_VERSION" \
  -syslibroot "$seek_activity_sdk" \
  -L "$seek_activity_runtime/iphoneos" -L "$seek_activity_sdk/usr/lib/swift" \
  -lSystem -lswiftCore -lobjc -framework Foundation -application_extension \
  -e _NSExtensionMain \
  -rpath /usr/lib/swift -rpath '@executable_path/../../Frameworks' -rpath '@executable_path/Frameworks' \
  .build/SeekActivity.o -o "$seek_activity_output/SeekActivity"
python3 - "$seek_activity_output" <<'PY'
from pathlib import Path
import os, plistlib, shutil, sys
out = Path(sys.argv[1])
info = plistlib.loads(Path('SeekActivity/Info.plist').read_bytes())
app = plistlib.loads(Path('Config/Info-xtool.plist').read_bytes())
info.update(CFBundleExecutable='SeekActivity', CFBundleIdentifier='app.seekapi.ios.activity',
            CFBundleName='SeekActivity', CFBundleVersion=app['CFBundleVersion'],
            CFBundleShortVersionString=app['CFBundleShortVersionString'],
            MinimumOSVersion='17.0', CFBundleSupportedPlatforms=['iPhoneOS'],
            UIDeviceFamily=[1, 2], DTPlatformName='iphoneos', DTSDKName='iphoneos'+os.environ['SEEK_IOS_SDK_VERSION'])
(out/'Info.plist').write_bytes(plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
for brand in ['OpenAI','Claude','Gemini','DeepSeek']:
    name = 'Model'+brand
    shutil.copyfile(Path('SeekActivity/Resources')/(name+'@3x.png'), out/(name+'@3x.png'))
    (out/(name+'.png')).unlink(missing_ok=True)
PY
echo "Built native WidgetKit/ActivityKit extension: $seek_activity_output"
