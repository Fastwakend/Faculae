"""Install the approved Faculae icons and generate the existing app accent color."""

import json
from pathlib import Path

from create_facula_icons import install_icons


def generate():
    root = Path(__file__).resolve().parent.parent / "SeekAPI/Resources/Assets.xcassets"
    install_icons()
    (root / "Contents.json").write_text('{"info":{"author":"xcode","version":1}}', encoding="utf-8")
    accent = root / "AccentColor.colorset"
    accent.mkdir(exist_ok=True)
    (accent / "Contents.json").write_text(json.dumps({"colors": [{
        "idiom": "universal", "color": {"color-space": "srgb", "components": {
            "red": "0.27", "green": "0.40", "blue": "0.96", "alpha": "1.0"
        }}
    }], "info": {"author": "xcode", "version": 1}}, indent=2), encoding="utf-8")
    print("Installed exact approved Faculae light/dark icons and existing accent color.")


if __name__ == "__main__":
    generate()
