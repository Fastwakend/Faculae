"""Merge compiled iOS assets and their primary-icon metadata into an unsigned IPA.

The asset catalog carries the dark appearance. A second loose PNG alone would
not let SpringBoard resolve the primary icon for the selected Home Screen style.
"""

import argparse
import plistlib
import zipfile
from pathlib import Path


def embed(ipa, assets):
    ipa, assets = Path(ipa), Path(assets)
    prefix = "Payload/SeekAPI.app/"
    partial = plistlib.loads((assets / "AppIcon-Info.plist").read_bytes())
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        assert partial[key]["CFBundlePrimaryIcon"]["CFBundleIconName"] == "AppIcon", key
    assert (assets / "Assets.car").read_bytes().startswith(b"BOMStore"), "Invalid compiled catalog"
    resources = {"Assets.car": assets / "Assets.car"}
    for path in assets.glob("AppIcon*.png"):
        resources[path.name] = path
    for key in ("CFBundleIcons", "CFBundleIcons~ipad"):
        for stem in partial[key]["CFBundlePrimaryIcon"].get("CFBundleIconFiles", []):
            assert any(name.startswith(stem) for name in resources), stem
    temporary = ipa.with_suffix(".with-assets.ipa")
    with zipfile.ZipFile(ipa) as source, zipfile.ZipFile(temporary, "w", zipfile.ZIP_DEFLATED) as output:
        info = plistlib.loads(source.read(prefix + "Info.plist"))
        # Replace xtool's single-PNG registration with the catalog's primary icon.
        for key in ("CFBundleIconFile", "CFBundleIconFiles", "CFBundleIconName", "CFBundleIcons", "CFBundleIcons~ipad"):
            info.pop(key, None)
        info.update(partial)
        replaced = {prefix + name for name in resources} | {prefix + "Info.plist"}
        for item in source.infolist():
            if item.filename not in replaced:
                output.writestr(item, source.read(item))
        output.writestr(prefix + "Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
        for name, path in sorted(resources.items()):
            output.write(path, prefix + name)
    with zipfile.ZipFile(temporary) as output:
        assert output.testzip() is None
        assert output.read(prefix + "Assets.car") == (assets / "Assets.car").read_bytes()
    temporary.replace(ipa)
    print(f"Embedded Assets.car and native primary-icon metadata ({len(resources)} resources); CRC verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("assets", type=Path)
    args = parser.parse_args()
    embed(args.ipa, args.assets)
