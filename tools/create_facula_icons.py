"""Install or export the exact user-approved Faculae light/dark artwork.

Only Python's standard library is needed. The checked-in master PNGs are
copied without rerendering, so generating assets preserves the selected pixels.
The superseded C-shaped design generator is archived with the v1 preview.
"""

import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ARTWORK = ROOT / "tools/artwork/facula"
ICONSET = ROOT / "SeekAPI/Resources/Assets.xcassets/AppIcon.appiconset"
EXPORT = ROOT / "artifacts/Faculae-Icons-approved/AppIcon.appiconset"


def approved_images():
    manifest = json.loads((ARTWORK / "manifest.json").read_text(encoding="utf-8"))
    assert manifest["size"] == [1024, 1024]
    assert [item["appearance"] for item in manifest["images"]] == ["light", "dark"]
    images = []
    for item in manifest["images"]:
        source = ARTWORK / item["filename"]
        data = source.read_bytes()
        assert hashlib.sha256(data).hexdigest() == item["sha256"], source
        assert data[:8] == b"\x89PNG\r\n\x1a\n" and data[12:16] == b"IHDR", source
        # RGB8, no alpha, full 1024px square. iOS supplies its own icon mask.
        assert struct.unpack_from(">IIBB", data, 16) == (1024, 1024, 8, 2), source
        images.append((item, source))
    return images


def write_iconset(destination):
    images = approved_images()  # Validate both masters before changing resources.
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    declarations = []
    for item, source in images:
        shutil.copyfile(source, destination / item["asset_filename"])
        declaration = {"filename": item["asset_filename"], "idiom": "universal",
                       "platform": "ios", "size": "1024x1024"}
        if item["appearance"] == "dark":
            declaration["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
        declarations.append(declaration)
    contents = {"images": declarations, "info": {"author": "xcode", "version": 1}}
    (destination / "Contents.json").write_text(json.dumps(contents, indent=2) + "\n", encoding="utf-8")
    return destination


def install_icons():
    return write_iconset(ICONSET)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Update the project's AppIcon asset set")
    options = parser.parse_args()
    destination = install_icons() if options.install else write_iconset(EXPORT)
    print(f"Faculae approved light/dark icon set: {destination}")
