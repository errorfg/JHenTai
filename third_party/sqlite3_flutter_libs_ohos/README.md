# sqlite3_flutter_libs for HarmonyOS

The Dart side is pub.dev's `sqlite3_flutter_libs` 0.5.42 unchanged. The
`ohos/` module is a plugin that only registers itself; the native library
comes from the ohpm package `sqlite3-native-library`, which `oh-package.json5`
depends on and which puts `libsqlite3.so` into the HAP, where `package:sqlite3`
finds it (see `lib/src/database/database.dart`).

Only HarmonyOS builds use this package: `tool/ohos/prepare.sh` writes it into
`pubspec_overrides.yaml`. Layout after https://github.com/SageMik/sqlite3-ohos.dart
(`sqlite3_flutter_libs-0.5.25-ohos`).
