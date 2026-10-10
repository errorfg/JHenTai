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

`prepare.sh` changes three files in the working tree, none of which is to be
committed in that state: `pubspec_overrides.yaml` (ignored by git),
`pubspec.lock` (resolved for the HarmonyOS SDK) and `pubspec.yaml` (a marked
`hooks:` block at the end). `--undo` reverts all three.

The HAP is written to `ohos/entry/build/default/outputs/default/`:
`entry-default-unsigned.hap`, or `entry-default-signed.hap` once
`ohos/build-profile.json5` has a signing configuration.

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
