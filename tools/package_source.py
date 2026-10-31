"""Package Faculae sources without credentials or build products."""
from pathlib import Path
import zipfile

root = Path(__file__).resolve().parent.parent
output = root / "artifacts/SeekAPI-source.zip"
output.parent.mkdir(exist_ok=True)
include = ["SeekAPI", "SeekActivity", "SeekShare", "SeekAPI.xcodeproj", "Packages", "Config", "scripts", "tools", "docs", ".github", "README.md", ".gitignore", ".gitattributes", "Package.swift", "xtool.yml"]
files = []
for name in include:
    path = root / name
    files += [path] if path.is_file() else [p for p in path.rglob("*") if p.is_file()]
files = [p for p in files if p.name != "Signing.xcconfig" and not any(part in ("__pycache__", ".build", "xcuserdata", "node_modules", "test-results", "playwright-report") for part in p.parts) and p.suffix not in (".ipa", ".p12", ".mobileprovision")]
with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(files):
        relative = file.relative_to(root)
        archive.write(file, "SeekAPI-source/" + relative.as_posix())
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    assert not any(n.endswith((".ipa", "Signing.xcconfig", ".p12", ".mobileprovision")) for n in archive.namelist())
print(f"Packaged {len(files)} files; {output.stat().st_size:,} bytes; archive CRC verified.")
