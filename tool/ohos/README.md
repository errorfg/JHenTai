# HarmonyOS build

The app builds for HarmonyOS NEXT with the HarmonyOS Flutter SDK
(`openharmony-tpc/flutter_flutter`, tag 3.41.10-ohos-1.0.1, Dart 3.11) against
DevEco Studio 26.0 (HarmonyOS SDK API 26). The other platforms keep Flutter
3.44; the code is written so that both compile. Background and the plugin
survey: `docs/superpowers/specs/2026-10-10-harmonyos-native-feasibility.md`.

## One-time setup

- DevEco Studio 26.0 at `/Applications/DevEco-Studio.app` (its SDK, ohpm,
  hvigor and node are used from there).
- The HarmonyOS Flutter SDK cloned to `~/vscode-project/flutter_ohos`
  (`git clone --depth 1 -b 3.41.10-ohos-1.0.1 https://gitcode.com/openharmony-tpc/flutter_flutter.git flutter_ohos`),
  bootstrapped once with `flutter_ohos/bin/flutter doctor`.
- JDK 17. Other locations: set `FLUTTER_OHOS_ROOT`, `DEVECO_HOME`, `JAVA_HOME`
  before sourcing `env.sh`.

## Building

```sh
source tool/ohos/env.sh      # PATH to the HarmonyOS Flutter SDK and DevEco tools
tool/ohos/prepare.sh         # writes pubspec_overrides.yaml, adds the sqlite3 hook setting, pub get
flutter build hap --debug -t lib/src/main.dart
tool/ohos/prepare.sh --undo  # back to the normal tree
```

`prepare.sh` changes four files in the working tree, none of which is to be
committed in that state: `pubspec_overrides.yaml` (ignored by git),
`pubspec.lock` (resolved for the HarmonyOS SDK), `pubspec.yaml` (a marked
`hooks:` block at the end) and `ohos/build-profile.json5` (the signing
configuration between its markers). `--undo` reverts all four. Run `--undo`
with the normal `flutter` on PATH, not after `source tool/ohos/env.sh`, or
the lock is resolved with the HarmonyOS SDK again.

It also patches the HarmonyOS Flutter SDK once (`patch_sdk.py`): its asset
bundling for debug builds leaves out `NativeAssetsManifest.json`, without which
the Dart VM cannot resolve the `@Native` symbols of `package:sqlite3` in JIT
mode. After the patch the flutter tool rebuilds itself on its next run.

## Signing

`ohos/signing.local.json5` (not in git) holds one entry of `signingConfigs`:
the debug certificate and key store this machine already has, and the debug
profile issued for `com.gallery.reader` (bundle name, certificate, device
UDIDs). The certificate is per account and signs any number of apps; only the
profile is per app, so a new profile is all a new app needs - do not let a
tool regenerate the certificate, every app signed with the old key would then
have to be uninstalled before it can be updated. The passwords in the file
are the encrypted form hvigor writes, valid on this machine only.

## Installing

```sh
$HDC tconn <ip:port>                       # wireless debugging; Connected in `$HDC list targets -v`
$HDC file send build/ohos/hap/entry-default-signed.hap /data/local/tmp/app.hap
$HDC shell "bm install -r -p /data/local/tmp/app.hap"
$HDC shell "aa start -a EntryAbility -b com.gallery.reader -m entry"
$HDC shell hilog | grep com.gallery.reader   # Dart log lines appear as "flutter settings log message"
```

`bm install` answering `install already exist` (code 9568276) after an
interrupted install: `bm uninstall -n com.gallery.reader`, then install again.

The HAP is written to `ohos/entry/build/default/outputs/default/` and copied
to `build/ohos/hap/`: `entry-default-unsigned.hap`, or `entry-default-signed.hap`
when a signing configuration is in place (see below).

## What the HarmonyOS tree differs in

- `ohos/pubspec_overrides.ohos.yaml`: the dependency overrides of
  `pubspec.yaml` plus the community's HarmonyOS ports of the plugins, and
  packages of our own: `third_party/sqlite3_flutter_libs_ohos` (ships
  libsqlite3.so), `ohos/stubs/saver_gallery` (no gallery saving yet),
  `ohos/patched/flex_color_picker` (a `default` branch in two switches).
- `hooks.user_defines.sqlite3.source: system` (added by `prepare.sh`):
  package:sqlite3 3.x loads its library through a native-assets build hook,
  whose default is a prebuilt download that has no HarmonyOS build.

## Not available on HarmonyOS yet

file_picker (no port with a matching package name), video_player (its
port's dependencies clash with drift_dev), saving a page to the gallery,
copying a page to the clipboard, reading the system proxy, volume-key page
turning.

## Device

Wireless debugging: `$HDC tconn <ip:port>`, then `$HDC list targets -v` must
say Connected (confirm the prompt on the phone the first time). Signing and
installing: see the notes referenced in the feasibility document, section 6.
