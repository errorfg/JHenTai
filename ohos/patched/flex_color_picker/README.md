# flex_color_picker, patched for HarmonyOS

Copy of pub.dev's flex_color_picker 3.8.0 (`lib/`, `assets/`, `LICENSE`) with
one change: the two `switch (platform)` statements in
`lib/src/functions/picker_functions.dart` get a `default` branch, because the
HarmonyOS Flutter SDK adds `TargetPlatform.ohos` and Dart rejects a switch
over an enum that misses a value. Only HarmonyOS builds use this copy
(`ohos/pubspec_overrides.ohos.yaml`); the other platforms take the package
from pub.dev. To update: copy the new version over, re-apply the two
`default` branches.
