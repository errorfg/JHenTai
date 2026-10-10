#!/usr/bin/env python3
"""Patches the HarmonyOS Flutter SDK in place (idempotent); run by prepare.sh.

Debug HAPs lack flutter_assets/NativeAssetsManifest.json: the SDK's
OhosAssetBundle target (packages/flutter_tools/lib/src/build_system/targets/ohos.dart)
copies the assets without the manifest that the generic CopyFlutterBundle
target adds, so in JIT mode the Dart VM cannot resolve @Native symbols of
packages built through build hooks (package:sqlite3: "Couldn't resolve native
function 'sqlite3_temp_directory'"). Release builds are not affected; the AOT
snapshot carries the mapping. Seen with 3.41.10-ohos-1.0.1.

Usage: patch_sdk.py <flutter_ohos root>. Prints "patched" when it changed a
file (the tool snapshot must then be rebuilt), "unchanged" otherwise.
"""
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
target = root / 'packages/flutter_tools/lib/src/build_system/targets/ohos.dart'
source = target.read_text()
marker = "// JHenTai: NativeAssetsManifest.json for JIT, as CopyFlutterBundle adds it."
if marker in source:
    print('unchanged')
    sys.exit(0)

old_call = """    final Depfile assetDepfile = await copyAssets(
      environment,
      outputDirectory,
      dartHookResult: dartHookResult,
      targetPlatform: TargetPlatform.ohos,
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
    );
"""
new_call = """    final Depfile assetDepfile = await copyAssets(
      environment,
      outputDirectory,
      dartHookResult: dartHookResult,
      targetPlatform: TargetPlatform.ohos,
      buildMode: buildMode,
      flavor: environment.defines[kFlavor],
      %s
      additionalContent: <String, DevFSContent>{
        'NativeAssetsManifest.json': DevFSFileContent(
          environment.buildDir.childFile('native_assets.json'),
        ),
      },
    );
""" % marker
old_import = "import '../../build_info.dart';\n"
new_import = "import '../../build_info.dart';\nimport '../../devfs.dart';\n"
if source.count(old_call) != 1 or source.count(old_import) != 1:
    print('ohos.dart does not look like 3.41.10-ohos-1.0.1; not patched', file=sys.stderr)
    sys.exit(1)
target.write_text(source.replace(old_call, new_call).replace(old_import, new_import))
print('patched')
