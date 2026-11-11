"""Bundle pure-Python parsers; never installs into or changes Hermes' environment."""
from pathlib import Path
import importlib.metadata
import json
import shutil
import sys
import yaml
import dotenv

dest = Path(sys.argv[1])
for module, distribution in [(yaml, "PyYAML"), (dotenv, "python-dotenv")]:
    source = Path(module.__file__).parent
    target = dest / "vendor" / source.name
    shutil.copytree(source, target, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__", "*.so", "*.pyc"))
    dist = importlib.metadata.distribution(distribution)
    for file in dist.files or []:
        if "license" in str(file).lower() and file.name.lower().startswith("license"):
            license_dest = dest / "licenses" / (distribution + "-LICENSE")
            license_dest.parent.mkdir(exist_ok=True)
            shutil.copyfile(dist.locate_file(file), license_dest)
(dest / "runtime.json").write_text(json.dumps({"python": sys.executable}, indent=2) + "\n")
