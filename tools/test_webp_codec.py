"""Exercise the vendored encoder/decoder on Linux without an iPhone or network."""
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parent.parent
library = root / "Packages/SeekWebP"
compiler = shutil.which("clang") or shutil.which("cc")
assert compiler, "A native C compiler is required"
sources = sorted(p for folder in ("src/dec", "src/enc", "src/dsp", "src/utils", "sharpyuv")
                 for p in (library / folder).glob("*.c"))
with tempfile.TemporaryDirectory(prefix="seek-webp-tests-") as temporary:
    binary = Path(temporary) / "webp-tests"
    subprocess.run([compiler, "-O1", "-DWEBP_DISABLE_SIMD", "-I", str(library),
                    str(root / "tools/tests/WebPCodecTests.c"), *(str(p) for p in sources), "-lm", "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
report = dict(cases=2, failures=0, source_c_files=len(sources), platform="native Linux C; not iOS runtime",
              checks=["lossless exact pixel round trip", "lossy quality 0/25/50/75/100, dimensions and opaque alpha"])
(root / "artifacts/webp-codec-tests.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report))
