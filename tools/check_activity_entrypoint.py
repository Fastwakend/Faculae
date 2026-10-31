"""Guard the actual WidgetKit executable entry point, rather than only its imports."""
from pathlib import Path
import json
import sys
import zipfile
from inspect_ipa import macho

with zipfile.ZipFile(Path(sys.argv[1])) as archive:
    result = macho(archive.read("Payload/SeekAPI.app/PlugIns/SeekActivity.appex/SeekActivity"))
entry = result.get("entrypoint", {})
print(json.dumps(entry))
assert entry.get("symbol") == "_NSExtensionMain", "WidgetKit requires Foundation's _NSExtensionMain bootstrap"
