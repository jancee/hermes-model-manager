#!/bin/bash
set -euo pipefail
STUDIO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STUDIO_APP="${STUDIO_APP:-$STUDIO_ROOT/dist/Hermes Model Studio.app}"
source "$STUDIO_ROOT/scripts/python-env.sh"
mkdir -p "$STUDIO_APP/Contents/MacOS" "$STUDIO_APP/Contents/Resources"
cp "$STUDIO_ROOT/Resources/bridge.py" "$STUDIO_APP/Contents/Resources/bridge.py"
cp -R "$STUDIO_ROOT/Resources/Locales" "$STUDIO_APP/Contents/Resources/"
cp "$STUDIO_ROOT/LICENSE" "$STUDIO_ROOT/THIRD_PARTY_NOTICES.md" "$STUDIO_APP/Contents/Resources/"
"$STUDIO_PYTHON" "$STUDIO_ROOT/scripts/vendor.py" "$STUDIO_APP/Contents/Resources"
/usr/bin/swiftc -O -parse-as-library -swift-version 5 -target "$STUDIO_ARCH-apple-macosx13.0" \
  "$STUDIO_ROOT"/Sources/*.swift \
  -o "$STUDIO_APP/Contents/MacOS/HermesModelStudio" -framework SwiftUI -framework AppKit
cp "$STUDIO_ROOT/Resources/Info.plist" "$STUDIO_APP/Contents/Info.plist"
"$STUDIO_PYTHON" "$STUDIO_ROOT/scripts/stamp-version.py" "$STUDIO_APP/Contents/Info.plist"
/usr/bin/swift "$STUDIO_ROOT/scripts/icon.swift" "$STUDIO_ROOT/dist/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STUDIO_ROOT/dist/AppIcon.iconset" -o "$STUDIO_APP/Contents/Resources/AppIcon.icns"
/usr/bin/codesign --force --sign - "$STUDIO_APP"
printf '%s\n' "$STUDIO_APP"
