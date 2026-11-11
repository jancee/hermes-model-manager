"""Check public source files and local Markdown links, excluding ignored artifacts."""
from pathlib import Path
import re
import subprocess
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
listed = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=ROOT)
paths = sorted({Path(name) for name in listed.decode().split("\0") if name})
errors = []
excluded_parts = {"backups", "local-notes", "dist", ".venv", ".build-venv", "__pycache__"}
secret_patterns = [
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----",
    r"\b(?:ghp_|github_pat_)[A-Za-z0-9_]{30,}\b",
    r"\bsk-(?:proj-)?[A-Za-z0-9_-]{30,}\b",
    r"/Users/[A-Za-z0-9._-]+/",
]

for relative in paths:
    path = ROOT / relative
    if excluded_parts.intersection(relative.parts) or relative.name == ".env":
        errors.append(f"Private or generated file included: {relative}")
    if not path.is_file():
        errors.append(f"Listed file is missing: {relative}")
        continue
    if path.suffix.lower() in {".png", ".icns"}:
        if not relative.is_relative_to("docs/assets"):
            errors.append(f"Unexpected binary asset: {relative}")
        continue
    try:
        source = path.read_text()
    except UnicodeDecodeError:
        errors.append(f"Unexpected binary file: {relative}")
        continue
    if any(re.search(pattern, source) for pattern in secret_patterns):
        errors.append(f"Possible secret or personal absolute path: {relative} (inspect locally)")
    if path.suffix.lower() == ".md":
        for target in re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", source):
            target = target.strip().strip("<>")
            parsed = urlsplit(target)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            if not (path.parent / unquote(parsed.path)).exists():
                errors.append(f"Broken Markdown link in {relative}: {target}")

for required in ("README.md", "README.zh-CN.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "VERSION"):
    if not (ROOT / required).is_file():
        errors.append(f"Missing public project file: {required}")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
print(f"Project checks passed: {len(paths)} public files, Markdown links and inclusion checks")
