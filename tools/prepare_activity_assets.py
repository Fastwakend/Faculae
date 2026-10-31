"""Prepare 30pt @3x artwork for the ActivityKit extension (requires Pillow)."""
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
output = ROOT / "SeekActivity/Resources"
output.mkdir(exist_ok=True)
for brand in ("OpenAI", "Claude", "Gemini", "DeepSeek"):
    source = ROOT / f"SeekAPI/Resources/Assets.xcassets/Model{brand}.imageset/Model{brand}.png"
    with Image.open(source) as image:
        image.convert("RGBA").resize((90, 90), Image.Resampling.LANCZOS).save(output / f"Model{brand}@3x.png", optimize=True)
print("Prepared four 90px / 30pt ActivityKit logos.")
