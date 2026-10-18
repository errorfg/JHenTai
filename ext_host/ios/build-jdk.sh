#!/bin/bash
# Builds the OpenJDK the iOS app carries, and puts it where the tachi_host
# pod takes it (ext_host/flutter/ios/jdk/):
#   - libffi for iOS (Zero's calls into native code);
#   - openjdk/mobile for iOS devices, with jdk-ios.patch: the Zero VM and
#     the JDK's native libraries as static archives;
#   - a macOS JDK from the same source, only for its jlink and jmod;
#   - the runtime image: java.base, java.logging, jdk.unsupported, jdk.zipfs;
#   - the host jar (ext_host/jvm).
#
# Usage: ext_host/ios/build-jdk.sh [work directory]   (default: ext_host/ios/work)
# Needs Xcode, autoconf, curl, and about 15 GB in the work directory.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
EXT_HOST="$(cd "$HERE/.." && pwd)"
WORK="${1:-$HERE/work}"
OUT="$EXT_HOST/flutter/ios/jdk"

# Pinned sources.
MOBILE_REPO=https://github.com/openjdk/mobile.git
MOBILE_COMMIT=c1ed06aaef34c8dccf71e236d1ffa20918a77cfb
LIBFFI_VERSION=3.8.0
BOOT_JDK_URL=https://github.com/adoptium/temurin26-binaries/releases/download/jdk-26.0.2.1%2B1/OpenJDK26U-jdk_aarch64_mac_hotspot_26.0.2.1_1.tar.gz
BOOT_JDK_SHA256=8c77a069a150c5b1c80280269ba062463053ebb7619ddef38dcfe3921fc60bdd
VERSION_OPT=gallery
MODULES=java.base,java.logging,jdk.unsupported,jdk.zipfs

mkdir -p "$WORK"
cd "$WORK"

# Boot JDK.
if [ ! -d bootjdk ]; then
  mkdir -p bootjdk
  curl -sSfL -o bootjdk/jdk.tar.gz "$BOOT_JDK_URL"
  echo "$BOOT_JDK_SHA256  bootjdk/jdk.tar.gz" | shasum -a 256 -c
  tar -xzf bootjdk/jdk.tar.gz -C bootjdk
fi
BOOT="$(echo "$WORK"/bootjdk/jdk-*/Contents/Home)"

# libffi.
if [ ! -f libffi-ios/lib/libffi.a ]; then
  curl -sSfL -o libffi.tar.gz "https://github.com/libffi/libffi/releases/download/v$LIBFFI_VERSION/libffi-$LIBFFI_VERSION.tar.gz"
  rm -rf "libffi-$LIBFFI_VERSION" && tar -xzf libffi.tar.gz
  SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  (
    cd "libffi-$LIBFFI_VERSION"
    CC="$(xcrun --sdk iphoneos -f clang) -arch arm64 -isysroot $SDK -miphoneos-version-min=13.0" CFLAGS=-O2 \
      ./configure --host=aarch64-apple-darwin --prefix="$WORK/libffi-ios" --enable-static --disable-shared --disable-docs
    make -j8 && make install
  )
fi

# OpenJDK source.
if [ ! -d mobile ]; then
  git init -q mobile
  git -C mobile remote add origin "$MOBILE_REPO"
  git -C mobile fetch -q --depth 1 origin "$MOBILE_COMMIT"
  git -C mobile checkout -q FETCH_HEAD
fi
# jdk-ios.patch: the statically linked VM looks up the JDK's symbols in the
# whole process, as it sits in the tachi_host framework rather than in the
# app's executable.
if ! git -C mobile apply --reverse --check "$HERE/jdk-ios.patch" 2>/dev/null; then
  git -C mobile apply "$HERE/jdk-ios.patch"
fi
cd mobile

# iOS: static libraries, Zero VM, and the classes of the runtime's other
# modules. static-libs-image compiles only some of those; the modules' full
# targets would also link a dynamic libjvm, which iOS cannot.
if [ ! -f build/ios-aarch64-zero-release/spec.gmk ]; then
  sh configure --disable-warnings-as-errors --openjdk-target=aarch64-macos-ios --with-boot-jdk="$BOOT" \
    --with-libffi-include="$WORK/libffi-ios/include" --with-libffi-lib="$WORK/libffi-ios/lib" \
    --with-cups-include="$(xcrun --sdk macosx --show-sdk-path)/usr/include" \
    --with-sysroot="$(xcrun --sdk iphoneos --show-sdk-path)" --with-debug-level=release \
    --with-native-debug-symbols=none --with-version-opt=$VERSION_OPT
fi
CLASS_TARGETS=""
for m in ${MODULES//,/ }; do
  [ "$m" = java.base ] || CLASS_TARGETS="$CLASS_TARGETS $m-java"
done
make CONF=ios-aarch64-zero-release static-libs-image $CLASS_TARGETS

# macOS: jlink and jmod of the same build. Xcode 26 no longer ships the
# Metal compiler; the modules built here do not need it.
if [ ! -f build/macos-host/spec.gmk ]; then
  sh configure --disable-warnings-as-errors --with-boot-jdk="$BOOT" --with-debug-level=release \
    --with-native-debug-symbols=none --with-jvm-variants=server --with-conf-name=macos-host \
    --with-version-opt=$VERSION_OPT METAL=/usr/bin/true METALLIB=/usr/bin/true
fi
make CONF=macos-host java.base jdk.jlink jdk.zipfs java.logging jdk.unsupported jdk.jlink-launchers java.base-launchers

IOS=build/ios-aarch64-zero-release
HOSTBIN=build/macos-host/jdk/bin

# Runtime image. Exploded modules carry no target platform; jmods do.
rm -rf "$WORK/jmods" "$WORK/runtime"
mkdir -p "$WORK/jmods/libs"
cp -R "$IOS/support/modules_libs/java.base/." "$WORK/jmods/libs/"
rm -rf "$WORK/jmods/libs/zero" "$WORK/jmods/libs/"_the.* "$WORK/jmods/libs/jrt-fs.jar"
"$HOSTBIN/jmod" create --class-path "$IOS/jdk/modules/java.base" --config "$IOS/support/modules_conf/java.base" \
  --libs "$WORK/jmods/libs" --target-platform macos-aarch64 "$WORK/jmods/java.base.jmod"
for m in ${MODULES//,/ }; do
  [ "$m" = java.base ] || "$HOSTBIN/jmod" create --class-path "$IOS/jdk/modules/$m" --target-platform macos-aarch64 "$WORK/jmods/$m.jmod"
done
"$HOSTBIN/jlink" --module-path "$WORK/jmods" --add-modules "$MODULES" --output "$WORK/runtime" \
  --compress zip-6 --strip-debug --no-header-files --no-man-pages

# Host jar.
(cd "$EXT_HOST" && ./gradlew -q :jvm:hostJar)

# Into the pod.
rm -rf "$OUT"
mkdir -p "$OUT/include" "$OUT/lib" "$OUT/home/lib"
cp "$IOS/jdk/include/jni.h" "$IOS/jdk/include/ios/jni_md.h" "$OUT/include/"
cp "$IOS/images/static-libs/lib/zero/libjvm.a" "$OUT/lib/"
for lib in java net nio zip jimage verify; do
  cp "$IOS/images/static-libs/lib/lib$lib.a" "$OUT/lib/"
done
cp "$WORK/libffi-ios/lib/libffi.a" "$OUT/lib/"
cp -R "$WORK/runtime/." "$OUT/home/lib/"
cp "$EXT_HOST/build/dist/exthost.jar" "$OUT/exthost.jar"
echo "Done: $OUT"
