#!/bin/bash
# Baut "Dusk & Dawn.app" und packt sie mit README und Programme-Verknüpfung
# in Dusk-and-Dawn-<Version>.dmg. Die Version kommt aus build.sh.
set -euo pipefail
cd "$(dirname "$0")"

APP="Dusk & Dawn.app"
VERSION=$(sed -n 's|.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*|\1|p' build.sh)
DMG="Dusk-and-Dawn-$VERSION.dmg"

./build.sh --no-open

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

echo "→ Packe $DMG …"
ditto "$APP" "$STAGE/$APP"
cp README.md "$STAGE/README.md"
cp dmg/DS_Store "$STAGE/.DS_Store"   # Fensterlayout der DMG
ln -s /Applications "$STAGE/Programme"

hdiutil create -quiet -volname "Dusk & Dawn" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify -quiet "$DMG"

echo "✓ Fertig: $DMG"
