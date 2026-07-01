#!/usr/bin/env bash
set -euo pipefail

BUNDLE="build/linux/x64/release/bundle"
LINUXDEPLOY="${LINUXDEPLOY:-linuxdeploy-x86_64.AppImage}"

echo "Building Flutter release"
flutter build linux --release

echo "Staging AppImage files"
cp linux/com.dsinkerii.memefolder.desktop "$BUNDLE/"
cp linux/runner/app_icon.png "$BUNDLE/memefolder.png"
mkdir -p "$BUNDLE/usr/bin"
ln -sf ../../memefolder "$BUNDLE/usr/bin/memefolder"

echo "Building AppImage"
EXCLUDELIBS="*" ./"$LINUXDEPLOY" \
  --appdir "$BUNDLE" \
  --desktop-file "$BUNDLE/com.dsinkerii.memefolder.desktop" \
  --icon-file "$BUNDLE/memefolder.png" \
  --output appimage

echo "Doe!"
