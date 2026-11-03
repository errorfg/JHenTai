#!/bin/bash
# Builds the Linux release and packs it with the extension host:
# build/linux/JHenTai-<version>-Linux-<arch>.deb. Build Check and Build &
# Release both run this, so that a test package holds what a release holds.
#
# Usage: .github/scripts/package_linux_deb.sh <version> <arch: x64 | arm64>
set -euo pipefail

VERSION="$1"
ARCH="$2"
ROOT="$(pwd)"
NAME="JHenTai-$VERSION-Linux-$ARCH"

flutter build linux --release -t lib/src/main.dart

cd build/linux
mkdir -p "$NAME/opt/jhentai" "$NAME/usr/share/applications" "$NAME/usr/share/icons/hicolor/512x512/apps"
cp -r "$ARCH/release/bundle/"* "$NAME/opt/jhentai"
bash "$ROOT/ext_host/desktop/package.sh" "$NAME/opt/jhentai"
cp -r "$ROOT/linux/assets/DEBIAN" "$NAME"
chmod 0755 "$NAME/DEBIAN/postinst" "$NAME/DEBIAN/postrm"

cp "$ROOT/linux/assets/top.jtmonster.jhentai.desktop" "$NAME/usr/share/applications"
cp "$ROOT/assets/icon/JHenTai_512.png" "$NAME/usr/share/icons/hicolor/512x512/apps/top.jtmonster.jhentai.png"

sed -i "/^Version: /s/Version: .*/Version: $VERSION/" "$NAME/DEBIAN/control"
if [ "$ARCH" = "arm64" ]; then
  sed -i "/^Architecture: /s/Architecture: .*/Architecture: arm64/" "$NAME/DEBIAN/control"
fi

dpkg-deb --build --root-owner-group "$NAME"

# The app starts the extension host from exthost/ next to it
# (lib/src/network/tachi/tachi_host.dart).
CONTENTS="$(dpkg-deb -c "$NAME.deb")"
for wanted in ./opt/jhentai/exthost/exthost.jar ./opt/jhentai/exthost/jre/bin/java; do
  if ! grep -q " $wanted\$" <<<"$CONTENTS"; then
    echo "$wanted is missing from $NAME.deb" >&2
    exit 1
  fi
done
