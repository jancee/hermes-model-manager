#!/bin/bash
# Source this from a build/check script after setting STUDIO_ROOT.
if [[ -z "${STUDIO_PYTHON:-}" ]]; then
  if [[ -x "$STUDIO_ROOT/.venv/bin/python" ]]; then
    STUDIO_PYTHON="$STUDIO_ROOT/.venv/bin/python"
  else
    STUDIO_PYTHON="$(command -v python3 || true)"
  fi
fi
if [[ -z "$STUDIO_PYTHON" ]] || ! "$STUDIO_PYTHON" -c 'import sys; assert sys.version_info >= (3, 10); import yaml, dotenv' 2>/dev/null; then
  printf '%s\n' 'Python 3.10+ with PyYAML and python-dotenv is required.' 'Run: uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r requirements-dev.txt' >&2
  exit 1
fi
STUDIO_ARCH="${STUDIO_ARCH:-$(uname -m)}"
case "$STUDIO_ARCH" in arm64|x86_64) ;; *) printf '%s\n' 'Supported build architectures: arm64, x86_64' >&2; exit 1 ;; esac
