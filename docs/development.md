# Development

English | [简体中文](development.zh-CN.md)

## Setup

Install Xcode Command Line Tools and a Python environment manager. From the repository root:

```bash
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python -r requirements-dev.txt
```

Build scripts choose `STUDIO_PYTHON`, then the project `.venv/bin/python`, then `python3` on PATH. The interpreter must be Python 3.10+ with the pinned parsing dependencies installed.

## Checks

```bash
.venv/bin/python -m unittest discover -s tests -v
.venv/bin/python scripts/check-localization.py
.venv/bin/python scripts/check-project.py
bash scripts/check-ui.sh
bash scripts/build.sh
'dist/Hermes Model Studio.app/Contents/MacOS/HermesModelStudio' --self-test
```

- Python tests use temporary homes and local mock servers to check validation, backups, references, preference compatibility, discovery, and batch behavior.
- Localization checks cover resource parity and placeholder consistency. Native checks cover translated messages, preserved user values, sorting, selection, and text entry with trailing spaces.
- Project checks validate public Markdown links and reject common accidental inclusions of private files or secrets.
- The packaged self-test exercises the compiled Swift-to-Python path against a temporary home.

These checks do not write to a real Hermes configuration or issue inference requests. Manual acceptance in a running Hermes client remains a separate integration check.

## Demo previews

Render example data without opening a visible window or changing the saved language:

```bash
APP='dist/Hermes Model Studio.app/Contents/MacOS/HermesModelStudio'
"$APP" --language en --preview "$PWD/docs/assets/endpoints.en.png" --endpoints --sorted
"$APP" --language zh-Hans --preview "$PWD/docs/assets/endpoints.zh-CN.png" --endpoints --sorted
"$APP" --language en --preview "$PWD/docs/assets/models.en.png" --batch
```

Other preview options are `--history`, `--provider-editor`, and `--discovery`. Previews are rendered through an unshown AppKit host so native fields and scroll views appear in the output. Inspect both languages when changing layout.

## Build and installation

`VERSION` is the version source. The build stamps the bundle's version, compiles for macOS 13 or later on the host architecture, copies the adapter and language resources, bundles parsing dependencies and their licenses, creates an icon, and applies an ad-hoc signature.

```bash
bash scripts/build.sh
.venv/bin/python scripts/install.py
```

The installer checks bundle identity and signature, stages the new app in `~/Applications`, and preserves the previous app in the project's ignored `backups/` directory. It never quits a running application. Reopen the app to load the installed version.

`STUDIO_ARCH=arm64` or `STUDIO_ARCH=x86_64` overrides the compile target. Cross-compilation is not runtime acceptance on that architecture. This local build uses an external interpreter. The [release workflow](releasing.md) bundles Python and checks each architecture on its matching runner. Developer ID signing and notarization are not currently configured.

## Public repository hygiene

Only source, synthetic fixtures, documentation, demo screenshots, and license notices belong in Git. `.gitignore` excludes virtual environments, generated apps, local notes, backups, `.env` files, and logs. Do not force-add these directories.

Before publishing, review `git diff --cached`, run the project checks, and check screenshots for personal data. A pattern-based check is an aid to review, not proof that every secret has been removed. Keep the English and Chinese Markdown editions aligned with behavior changes.
