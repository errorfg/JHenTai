#!/usr/bin/env bash
# Puts the working tree into its HarmonyOS shape: writes pubspec_overrides.yaml
# from ohos/pubspec_overrides.ohos.yaml and resolves packages with the HarmonyOS
# Flutter SDK. Run `tool/ohos/prepare.sh --undo` to go back to the normal tree
# (removes the overrides, restores pubspec.lock from git, resolves with the
# `flutter` on PATH).
#
# pubspec.lock changes under the HarmonyOS SDK; do not commit it from here.
set -euo pipefail
cd "$(dirname "$0")/../.."

# sqlite3 3.x loads its native library through a build hook (native assets).
# Its default, a prebuilt download, has no HarmonyOS build; `system` makes the
# app load libsqlite3.so by name, which third_party/sqlite3_flutter_libs_ohos
# puts into the HAP. The hook's settings live in pubspec.yaml and apply to every
# platform, so they are only added to it for HarmonyOS builds, between markers.
HOOKS_BEGIN='# >>> ohos build only (tool/ohos/prepare.sh) >>>'
HOOKS_END='# <<< ohos build only <<<'

remove_hooks() {
  python3 - "$HOOKS_BEGIN" "$HOOKS_END" <<'PY'
import pathlib, sys
p = pathlib.Path('pubspec.yaml'); s = p.read_text()
a = s.find(sys.argv[1]); b = s.find(sys.argv[2])
if a >= 0 and b >= 0:
    p.write_text(s[:a].rstrip('\n') + '\n' + s[b + len(sys.argv[2]):].lstrip('\n'))
PY
}

# Signing: ohos/signing.local.json5 (not in git) holds one signingConfigs
# entry - certificate, key store and profile of this machine. It goes into
# ohos/build-profile.json5 between the markers there, and comes out again.
set_signing() {
  python3 - "$1" <<'PY'
import pathlib, re, sys
p = pathlib.Path('ohos/build-profile.json5'); s = p.read_text()
begin = '// >>> local signing (ohos/signing.local.json5, written by tool/ohos/prepare.sh) >>>\n'
end = '      // <<< local signing <<<'
a = s.index(begin) + len(begin); b = s.index(end)
local = pathlib.Path('ohos/signing.local.json5')
body = local.read_text() if sys.argv[1] == 'set' and local.exists() else ''
p.write_text(s[:a] + body + s[b:])
PY
}

if [ "${1:-}" = "--undo" ]; then
  rm -f pubspec_overrides.yaml
  remove_hooks
  set_signing unset
  git checkout -- pubspec.lock
  flutter pub get
  exit 0
fi

# Every override of pubspec.yaml must be repeated in the HarmonyOS file.
missing=0
while read -r name; do
  if ! grep -q "^  $name:" ohos/pubspec_overrides.ohos.yaml; then
    echo "ohos/pubspec_overrides.ohos.yaml lacks the pubspec.yaml override '$name'" >&2
    missing=1
  fi
done < <(awk '/^dependency_overrides:/{f=1;next} /^[a-z_]+:/{f=0} f && /^  [a-z_0-9]+:/{sub(":.*","",$1); print $1}' pubspec.yaml)
[ "$missing" = 0 ] || exit 1

source tool/ohos/env.sh

# The SDK needs one fix for debug builds (see patch_sdk.py); after a change
# the flutter tool is built again on its next run.
if [ "$(python3 tool/ohos/patch_sdk.py "$FLUTTER_OHOS_ROOT")" = "patched" ]; then
  rm -f "$FLUTTER_OHOS_ROOT/bin/cache/flutter_tools.snapshot" "$FLUTTER_OHOS_ROOT/bin/cache/flutter_tools.stamp"
fi

cp ohos/pubspec_overrides.ohos.yaml pubspec_overrides.yaml
set_signing set
remove_hooks
cat >> pubspec.yaml <<EOF_HOOKS

$HOOKS_BEGIN
hooks:
  user_defines:
    sqlite3:
      source: system
$HOOKS_END
EOF_HOOKS
flutter pub get
