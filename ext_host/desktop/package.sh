#!/bin/bash
# Puts the extension host into a desktop build: <dir>/exthost/exthost.jar and
# <dir>/exthost/jre, a runtime linked from the JDK this runs with (17 or
# later; its jlink must be next to java on PATH). The app starts
# exthost/jre/bin/java -jar exthost/exthost.jar (lib/src/network/tachi/tachi_host.dart).
#
# Usage: ext_host/desktop/package.sh <dir>
#   macOS:   <app>/Contents/Resources (sign the app again afterwards)
#   Windows: the folder with the .exe
#   Linux:   the bundle folder with the executable
set -euo pipefail

DEST="$1/exthost"
HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_HOST="$(cd "$HERE/.." && pwd)"

JAVA="$(command -v java)"
JAVA_BIN="$(cd "$(dirname "$(readlink -f "$JAVA" 2>/dev/null || echo "$JAVA")")" && pwd)"
JLINK="$JAVA_BIN/jlink"
[ -x "$JLINK" ] || JLINK="$JAVA_BIN/jlink.exe"

(cd "$EXT_HOST" && ./gradlew -q --no-daemon :jvm:hostJar)

# java.base and what the host and extensions use; jdk.zipfs for the dex
# converter's jar output; jdk.crypto.ec for TLS on JDKs before 22 (where it
# is a module of its own); java.xml for extensions parsing XML.
MODULES=java.base,java.logging,jdk.unsupported,jdk.zipfs,java.xml
if "$JAVA" --list-modules | grep -q '^jdk.crypto.ec@'; then
  MODULES="$MODULES,jdk.crypto.ec"
fi

rm -rf "$DEST"
mkdir -p "$DEST"
# jlink names its compression zip-6 from JDK 21 on, 2 before.
COMPRESS=zip-6
if [ "$("$JAVA" -XshowSettings:properties -version 2>&1 | sed -n 's/.*java.specification.version = \([0-9]*\).*/\1/p')" -lt 21 ]; then
  COMPRESS=2
fi
"$JLINK" --add-modules "$MODULES" --output "$DEST/jre" --strip-debug --no-man-pages --no-header-files --compress="$COMPRESS"
cp "$EXT_HOST/build/dist/exthost.jar" "$DEST/exthost.jar"
echo "Extension host in $DEST ($(du -sh "$DEST" | cut -f1))"
