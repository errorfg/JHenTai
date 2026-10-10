# chewie, patched for HarmonyOS

Copy of pub.dev's chewie 1.13.1 (`lib/`, `assets/`, `LICENSE`) with one
change: the `switch (Theme.of(context).platform)` in
`lib/src/helpers/adaptive_controls.dart` gets a `default` branch, because the
HarmonyOS Flutter SDK adds `TargetPlatform.ohos` and Dart rejects a switch
over an enum that misses a value. Only HarmonyOS builds use this copy
(`ohos/pubspec_overrides.ohos.yaml`); the other platforms take chewie from
pub.dev. The community's chewie port was not usable: it depends on the
video_player port, whose dependencies clash with drift_dev. To update: copy
the new version over, re-apply the `default` branch.
