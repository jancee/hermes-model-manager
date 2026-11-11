"""Keep the built application version aligned with the repository VERSION file."""
from pathlib import Path
import plistlib
import re
import sys

version = (Path(__file__).resolve().parents[1] / "VERSION").read_text().strip()
if not re.fullmatch(r"\d+\.\d+\.\d+", version):
    raise SystemExit("VERSION must contain a three-part numeric version")
path = Path(sys.argv[1])
info = plistlib.loads(path.read_bytes())
info["CFBundleShortVersionString"] = version
major, minor, patch = map(int, version.split("."))
info["CFBundleVersion"] = str(major * 10000 + minor * 100 + patch)
path.write_bytes(plistlib.dumps(info, sort_keys=False))
