"""Install our signed bundle with a preserved previous version; never quits any app."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import time
import uuid

root = Path(__file__).resolve().parents[1]
source = root / "dist" / "Hermes Model Studio.app"
applications = Path.home() / "Applications"
destination = applications / source.name
expected_id = "com.jancee.hermes-model-studio"


def info(app):
    with (app / "Contents" / "Info.plist").open("rb") as stream:
        data = plistlib.load(stream)
    if data.get("CFBundleIdentifier") != expected_id:
        raise SystemExit("Bundle identity does not match; no installation performed")
    return data


new_info = info(source)
old_info = info(destination) if destination.exists() else None
applications.mkdir(exist_ok=True)
staging = applications / (".HermesModelStudio-install-" + uuid.uuid4().hex + ".app")
shutil.copytree(source, staging, symlinks=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(staging)], check=True)
backup = None
if old_info:
    backup = root / "backups" / ("Hermes Model Studio-" + old_info["CFBundleShortVersionString"] + "-" + time.strftime("%Y%m%d-%H%M%S") + ".app")
    backup.parent.mkdir(exist_ok=True)
    if backup.exists():
        raise SystemExit("Backup already exists; no replacement performed")
    destination.rename(backup)
try:
    staging.rename(destination)
except BaseException:
    if backup is not None:
        backup.rename(destination)
    raise
print("Installed", new_info["CFBundleShortVersionString"], destination)
if backup:
    print("Previous application preserved:", backup)
