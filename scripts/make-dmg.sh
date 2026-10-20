#!/bin/zsh
# Builds the standalone app (scripts/make-app.sh --standalone: engine, Python and resources
# inside) and wraps it in build/Coastline.dmg, with an Applications link to drag it onto.
# Signed ad hoc only: on another Mac, the first launch needs right-click ▸ Open (or
# System Settings ▸ Privacy & Security ▸ Open Anyway). Run scripts/build-app.sh first.
set -e
ROOT=${0:A:h:h}
$ROOT/scripts/make-app.sh --standalone >/dev/null
STAGE=$(mktemp -d /tmp/coastline-dmg.XXXX)
cp -R $ROOT/build/Coastline.app $STAGE/
ln -s /Applications $STAGE/Applications
DMG=$ROOT/build/Coastline.dmg
rm -f $DMG
hdiutil create -volname Coastline -srcfolder $STAGE -fs APFS -format ULMO -ov $DMG >/dev/null
rm -rf "${STAGE:?}"
echo "$DMG ($(du -h $DMG | cut -f1))"
