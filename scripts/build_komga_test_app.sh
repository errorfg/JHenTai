#!/usr/bin/env bash
# Build a macOS release app for UI testing, isolated from the installed
# JHenTai: bundle identifier top.jtmonster.jhentai.komgatest.<short hash>,
# output dist/komga-test/JHenTai Komga 测试 <short hash>.app. Each build has
# its own data container. A dirty worktree gets a "-dirty" suffix.
set -euo pipefail
cd "$(dirname "$0")/.."

hash="$(git rev-parse --short=8 HEAD)"
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  hash="$hash-dirty"
fi
bundle_id="top.jtmonster.jhentai.komgatest.$hash"
out="dist/komga-test/JHenTai Komga 测试 $hash.app"

xcconfig=macos/Runner/Configs/AppInfo.xcconfig
cp "$xcconfig" "$xcconfig.test-build-backup"
trap 'mv "$xcconfig.test-build-backup" "$xcconfig"' EXIT

python3 - "$xcconfig" "$bundle_id" <<'PY'
import re, sys
path, bundle_id = sys.argv[1:3]
text = open(path).read()
text = re.sub(r'^PRODUCT_BUNDLE_IDENTIFIER = .*$', f'PRODUCT_BUNDLE_IDENTIFIER = {bundle_id}', text, flags=re.M)
open(path, 'w').write(text)
PY

flutter build macos --release -t lib/src/main.dart

mkdir -p dist/komga-test
rm -rf "$out"
cp -R build/macos/Build/Products/Release/jhentai.app "$out"
echo "Built $out ($bundle_id)"
