# Releasing

English | [简体中文](releasing.zh-CN.md)

Only macOS application binaries are packaged. Apple Silicon and Intel use separate ZIPs; GitHub also provides its standard source archives.

## Build a package

Use macOS, Xcode Command Line Tools, and the project's Python 3.12+ environment:

```bash
.venv/bin/python scripts/package-macos.py --arch arm64
.venv/bin/python scripts/package-macos.py --arch x86_64
```

Run each architecture on a matching Mac, or use the **Package macOS** GitHub Actions workflow. The packager refuses a different host architecture so release checks run natively without Rosetta. A successful cross-build alone is not a runtime test.

The script builds in a temporary directory, verifies the pinned Python download, embeds the runtime and license notices, and signs the nested binaries and app. It then creates a ZIP, extracts it to a different path, and runs the packaged integration check with a fresh home and no developer environment. The check explicitly requires the bundled interpreter. Signatures are checked again after execution to catch unintended writes inside the bundle.

Outputs are written to `dist/releases/`:

- `Hermes-Model-Studio-VERSION-macOS-arm64.zip`
- `Hermes-Model-Studio-VERSION-macOS-x86_64.zip`
- Matching `.zip.sha256` files.

Each app is checked for architecture consistency, escaping symlinks, development checkout paths, and non-system absolute library dependencies. The ZIP contains the application only; no Hermes configuration or credentials are included.

## GitHub Release

1. Update `VERSION`, both changelogs, and any versioned download links. Review the source diff and commit it.
2. Push the reviewed source, then dispatch **Package macOS** for that commit's branch. The workflow runs adapter, localization, documentation, and native checks on matching arm64 and Intel runners before uploading packages.
3. Confirm that both jobs passed and their run points to the intended commit. Download both artifacts using `gh run download` and verify their SHA-256 files.
4. Prepare bilingual release notes from the matching changelog sections, including installation instructions and the signing status. Save notes to a UTF-8 file.
5. Create and push an annotated version tag for the tested commit. Create a draft GitHub Release with `gh release create --verify-tag --draft --notes-file` and attach only the macOS ZIPs and checksum files.
6. Read back the uploaded assets and verify their sizes and digests. Publish the draft and confirm the release and downloads are publicly accessible.

Do not move an existing public tag or replace a published package silently. Use a new patch version for corrections.

## Runtime updates and signing

`scripts/python-runtime.json` pins the upstream Python version, release, archive URLs, SHA-256 values, and license-source commit. Update these together and preserve the corresponding upstream notices under `licenses/python-runtime/`. Never copy a personal virtual environment into a public release.

Packages are ad-hoc signed; no Developer ID certificate or notarization credentials are configured. The README links Apple's per-app opening instructions. A successful signature check proves bundle integrity, not Apple notarization or user acceptance.
