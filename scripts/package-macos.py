"""Build a relocatable macOS app, verify it after extraction, and create a ZIP."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
MACH_MAGIC = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"}


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def download_runtime(spec, arch):
    target = spec["targets"][arch]
    cache = ROOT / "dist/runtime-cache"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"python-{spec['version']}-{spec['release']}-{arch}.tar.gz"
    if not archive.exists():
        partial = archive.with_suffix(".partial")
        try:
            with urlopen(target["url"], timeout=60) as source, partial.open("wb") as output:
                shutil.copyfileobj(source, output)
            if hashlib.sha256(partial.read_bytes()).hexdigest() != target["sha256"]:
                raise RuntimeError("Downloaded Python checksum does not match the pinned manifest")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != target["sha256"]:
        raise RuntimeError("Cached Python checksum does not match the pinned manifest")
    return archive


def binaries(app):
    for path in app.rglob("*"):
        if path.is_file() and not path.is_symlink():
            with path.open("rb") as stream:
                if stream.read(4) in MACH_MAGIC:
                    yield path


def audit_bundle(app, arch, version):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info["CFBundleShortVersionString"] != version:
        raise RuntimeError("Bundle version does not match VERSION")
    manifest = json.loads((app / "Contents/Resources/runtime.json").read_text())
    if manifest["python"] != "Python/bin/python3":
        raise RuntimeError("Release contains a development interpreter path")
    for path in app.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(app.resolve()):
            raise RuntimeError("A bundle symlink points outside the app")
        if not path.is_file() or path.is_symlink():
            continue
        if str(ROOT).encode() in path.read_bytes():
            raise RuntimeError(f"Development checkout path found in {path.relative_to(app)}")
    for path in binaries(app):
        architecture = run("/usr/bin/lipo", "-archs", path, capture_output=True, text=True).stdout.strip()
        if architecture != arch:
            raise RuntimeError(f"Architecture mismatch in {path.relative_to(app)}")
        commands = run("/usr/bin/otool", "-l", path, capture_output=True, text=True).stdout
        minimums = re.findall(r"\bminos\s+(\d+(?:\.\d+)*)", commands)
        minimums += re.findall(r"cmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)", commands)
        if any(tuple(map(int, value.split(".")[:2])) > (13, 0) for value in minimums):
            raise RuntimeError(f"Binary requires a newer macOS than advertised: {path.relative_to(app)}")
        links = run("/usr/bin/otool", "-L", path, capture_output=True, text=True).stdout.splitlines()[1:]
        for line in links:
            dependency = line.strip().split(" (", 1)[0]
            if dependency.startswith("/") and not dependency.startswith(("/System/Library/", "/usr/lib/")):
                raise RuntimeError(f"Non-system absolute library dependency in {path.relative_to(app)}")
        run("/usr/bin/codesign", "--verify", "--strict", path, capture_output=True)
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=("arm64", "x86_64"), default=platform.machine())
    args = parser.parse_args()
    if sys.platform != "darwin" or sys.version_info < (3, 12):
        parser.error("Packaging requires macOS and Python 3.12 or later")
    silicon = subprocess.run(["/usr/sbin/sysctl", "-n", "hw.optional.arm64"], capture_output=True, text=True).stdout.strip()
    host_arch = "arm64" if silicon == "1" else platform.machine()
    if args.arch != host_arch:
        parser.error("Use a matching Mac or the Package macOS workflow; release checks must run natively, without Rosetta")
    version = (ROOT / "VERSION").read_text().strip()
    spec = json.loads((ROOT / "scripts/python-runtime.json").read_text())
    archive = download_runtime(spec, args.arch)
    output = ROOT / "dist/releases"
    output.mkdir(parents=True, exist_ok=True)
    destination = output / f"Hermes-Model-Studio-{version}-macOS-{args.arch}.zip"
    with tempfile.TemporaryDirectory(prefix="macos-package-", dir=ROOT / "dist") as temporary:
        work = Path(temporary)
        app = work / "build/Hermes Model Studio.app"
        env = dict(os.environ, STUDIO_ARCH=args.arch, STUDIO_APP=str(app))
        run("/bin/bash", ROOT / "scripts/build.sh", env=env, cwd=ROOT)
        resources = app / "Contents/Resources"
        with tarfile.open(archive) as source:
            source.extractall(work / "runtime", filter="data")
        shutil.move(work / "runtime/python", resources / "Python")
        shutil.copytree(ROOT / "licenses", resources / "licenses", dirs_exist_ok=True)
        (resources / "runtime.json").write_text(json.dumps({
            "python": "Python/bin/python3", "version": spec["version"],
            "architecture": args.arch, "sha256": spec["targets"][args.arch]["sha256"],
        }, indent=2) + "\n")
        # Sign nested Mach-O files before sealing the outer bundle.
        for path in binaries(app):
            run("/usr/bin/codesign", "--force", "--sign", "-", path, capture_output=True)
        run("/usr/bin/codesign", "--force", "--sign", "-", app)
        audit_bundle(app, args.arch, version)
        zipped = work / destination.name
        run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", app, zipped)
        # Run the exact extracted artifact from a path containing spaces, with a
        # fresh home and no Python/Hermes/developer environment on PATH.
        relocated = work / "relocated app"
        run("/usr/bin/ditto", "-x", "-k", zipped, relocated)
        checked = relocated / app.name
        isolated_home = work / "empty home"
        isolated_home.mkdir()
        isolated_env = {"HOME": str(isolated_home), "PATH": "/usr/bin:/bin", "TMPDIR": str(work), "LANG": "en_US.UTF-8"}
        executable = checked / "Contents/MacOS/HermesModelStudio"
        run(executable, "--self-test", "--require-bundled-runtime", env=isolated_env)
        audit_bundle(checked, args.arch, version)
        shutil.copyfile(zipped, destination)
    checksum = hashlib.sha256(destination.read_bytes()).hexdigest()
    destination.with_suffix(".zip.sha256").write_text(f"{checksum}  {destination.name}\n")
    print(f"Release package verified: {destination.name} ({destination.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
