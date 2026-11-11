#!/bin/bash
set -euo pipefail
STUDIO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$STUDIO_ROOT/scripts/python-env.sh"
mkdir -p "$STUDIO_ROOT/dist"
STUDIO_SOURCES=()
for source in "$STUDIO_ROOT"/Sources/*.swift; do
  if [[ "$source" != "$STUDIO_ROOT/Sources/main.swift" ]]; then STUDIO_SOURCES+=("$source"); fi
done
/usr/bin/swiftc -parse-as-library -swift-version 5 -target "$STUDIO_ARCH-apple-macosx13.0" \
  "${STUDIO_SOURCES[@]}" "$STUDIO_ROOT/tests/UIBehaviorChecks.swift" \
  -o "$STUDIO_ROOT/dist/UIBehaviorChecks" -framework SwiftUI -framework AppKit
STUDIO_RESOURCES="$STUDIO_ROOT/Resources" "$STUDIO_ROOT/dist/UIBehaviorChecks"
