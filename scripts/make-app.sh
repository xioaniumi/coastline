#!/bin/zsh
# Packages the built app as build/Coastline.app (double-click to run; drag to Applications if
# you like). Run scripts/build-app.sh first.
#
#   scripts/make-app.sh               the engine stays in this repo (the app finds it at the path
#                                     it was built from: keep the repo where it is)
#   scripts/make-app.sh --standalone  everything inside the app: a self-contained Python 3.11
#                                     (uv's managed CPython) with the engine's packages, the engine
#                                     and resources/ in Contents/Resources/Coastline, laid out as in
#                                     the repo. Runs on any Apple-silicon Mac with macOS 26+, no repo.
#                                     scripts/make-dmg.sh wraps it in a disk image.
set -e
STANDALONE=0
[[ ${1:-} == --standalone ]] && STANDALONE=1
ROOT=${0:A:h:h}
BIN=$ROOT/Coastline/.build/debug/Coastline
[[ -x $BIN ]] || { echo "build first: scripts/build-app.sh"; exit 1; }
APP=$ROOT/build/Coastline.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Coastline
# Icon: resources/icon/Coastline.icon (Icon Composer document: light, dark, tinted, clear).
# With Xcode's actool it's compiled into Assets.car, so macOS switches the looks itself;
# without Xcode, the .icns is drawn flat by scripts/support/make-icon.swift (same design).
ICON_DOC=$ROOT/resources/icon/Coastline.icon
ICNS=$ROOT/build/Coastline.icns
if [[ ! -f $ICNS || $ICON_DOC/icon.json -nt $ICNS || $ROOT/scripts/support/make-icon.swift -nt $ICNS ]]; then
  T=$(mktemp -d)
  mkdir -p $T/icon.iconset
  # Drawn flat (scripts/support/make-icon.swift explains why), on macOS's icon grid.
  swift $ROOT/scripts/support/make-icon.swift $T/icon.png
  for s in 16 32 128 256 512; do
    sips -z $s $s $T/icon.png --out $T/icon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s * 2)) $((s * 2)) $T/icon.png --out $T/icon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns $T/icon.iconset -o $ICNS
fi
cp $ICNS $APP/Contents/Resources/Coastline.icns
ICONNAME=""
if xcrun --find actool >/dev/null 2>&1; then
  # The real thing: the .icon compiled into Assets.car (light / dark / tinted / clear).
  xcrun actool $ICON_DOC --compile $APP/Contents/Resources --platform macosx --minimum-deployment-target 15.0 \
    --app-icon Coastline --output-partial-info-plist /tmp/coastline-icon.plist >/dev/null 2>&1 && ICONNAME=Coastline
fi
VERSION=$(cd $ROOT && git rev-list --count HEAD 2>/dev/null || echo 1)
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Coastline</string>
  <key>CFBundleDisplayName</key><string>Coastline</string>
  <key>CFBundleIdentifier</key><string>io.github.xioaniumi.coastline</string>
  <key>CFBundleExecutable</key><string>Coastline</string>
  <key>CFBundleIconFile</key><string>Coastline</string>
$( [[ -n $ICONNAME ]] && echo "  <key>CFBundleIconName</key><string>$ICONNAME</string>" )
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>io.github.xioaniumi.coastline.project</string>
    <key>UTTypeDescription</key><string>Coastline Job</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>coastline</string></array></dict>
  </dict></array>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>Coastline Job</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSItemContentTypes</key><array><string>io.github.xioaniumi.coastline.project</string></array>
  </dict></array>
</dict></plist>
PLIST
if (( STANDALONE )); then
  # The repo's layout inside the app (AppModel.repoRoot finds it there): engine/, resources/ and
  # python/ (a copy of uv's relocatable CPython, the venv's packages added to its site-packages).
  B=$APP/Contents/Resources/Coastline
  mkdir -p $B/engine
  PY=$(readlink -f "$(sed -n 's/^home = //p' $ROOT/engine/.venv/pyvenv.cfg)/..")
  rsync -a --exclude '__pycache__' --exclude 'EXTERNALLY-MANAGED' $PY/ $B/python/
  SITE=$B/python/lib/python3.11/site-packages
  # Not the dev tools, not the editable link back to the repo, and not VTK's Python modules and
  # matplotlib (OCP's wheel pulls them in; the engine never loads them).
  rsync -a --exclude '__pycache__' \
    --exclude 'vtkmodules' --exclude 'vtk*' --exclude 'matplotlib*' --exclude 'mpl_toolkits' \
    --exclude '_pytest' --exclude 'pytest*' --exclude 'pluggy*' --exclude 'iniconfig*' --exclude 'pybind11*' \
    --exclude '_virtualenv.*' --exclude '_editable_impl_*' --exclude 'coastline_engine*' \
    $ROOT/engine/.venv/lib/python3.11/site-packages/ $SITE/
  # Of VTK only the libraries OCP's binaries load (directly or through each other).
  VENV_SITE=$ROOT/engine/.venv/lib/python3.11/site-packages
  mkdir -p $SITE/vtkmodules/.dylibs
  $B/python/bin/python3.11 $ROOT/scripts/support/linked_dylibs.py $SITE/OCP $VENV_SITE/vtkmodules/.dylibs |
    while read -r lib; do cp $VENV_SITE/vtkmodules/.dylibs/$lib $SITE/vtkmodules/.dylibs/; done
  rsync -a --exclude '__pycache__' --exclude '*.pyc' $ROOT/engine/coastline_engine $B/engine/
  rsync -a --exclude '.DS_Store' $ROOT/resources $B/
  # Compiled once here, so the first launch isn't slow (and the bundle isn't written to later).
  $B/python/bin/python3.11 -m compileall -q $B/python/lib/python3.11 $B/engine >/dev/null 2>&1 || true
fi
codesign --force --sign - $APP >/dev/null 2>&1 || true
echo "$APP"
