"""Embed a separately cross-compiled app extension in the unsigned IPA."""
from pathlib import Path
import plistlib
import sys
import zipfile

ipa, extension = map(Path, sys.argv[1:])
prefix = "Payload/SeekAPI.app/PlugIns/" + extension.name + "/"
temporary = ipa.with_suffix(".with-extension.ipa")
with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as output:
    app_info = plistlib.loads(source.read("Payload/SeekAPI.app/Info.plist"))
    activity_info = plistlib.loads((extension / "Info.plist").read_bytes())
    assert activity_info["CFBundleIdentifier"] == app_info["CFBundleIdentifier"] + {"SeekActivity.appex": ".activity", "SeekShare.appex": ".share"}[extension.name]
    assert activity_info["CFBundleVersion"] == app_info["CFBundleVersion"]
    for item in source.infolist():
        if not item.filename.startswith(prefix):
            output.writestr(item, source.read(item))
    for file in sorted(extension.rglob("*")):
        if file.is_file():
            output.write(file, prefix + file.relative_to(extension).as_posix())
    if extension.name == "SeekShare.appex":
        # These are signing inputs, not proof of effective signed entitlements.
        output.write(Path(__file__).resolve().parent.parent / "Config/SeekAPI.entitlements",
                     "Payload/SeekAPI.app/ShareAppGroup.entitlements")
with zipfile.ZipFile(temporary) as output:
    assert output.testzip() is None
temporary.replace(ipa)
print(f"Embedded {extension.name}; archive CRC verified.")
