#!/bin/bash
# Baut "Dusk & Dawn.app" aus DuskAndDawn.swift.
# Voraussetzung: Xcode Command Line Tools (xcode-select --install), macOS 13+.
set -euo pipefail
cd "$(dirname "$0")"

APP="Dusk & Dawn.app"
BIN="DuskAndDawn"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

echo "→ Kompiliere …"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13" \
  DuskAndDawn.swift -o "$APP/Contents/MacOS/$BIN"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>local.duskanddawn</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>Dusk &amp; Dawn</string>
  <key>CFBundleDisplayName</key><string>Dusk &amp; Dawn</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

echo "→ Ad-hoc-Signatur …"
codesign --force --sign - "$APP"

echo "✓ Fertig: $APP"
[[ "${1:-}" == "--no-open" ]] || open "$APP"
