"""Writes integration_test/testext_apk.dart from the test extension APK.

Run from the repository root after `ext_host/gradlew -p ext_host :testext:testApk`.
"""
import base64
import pathlib

apk = pathlib.Path('ext_host/jvm/src/test/resources/testext.apk').read_bytes()
b64 = base64.b64encode(apk).decode()
lines = [b64[i:i + 100] for i in range(0, len(b64), 100)]
pathlib.Path('integration_test/testext_apk.dart').write_text(
    "// The test extension (ext_host/testext), as built into\n"
    "// ext_host/jvm/src/test/resources/testext.apk. Regenerate with\n"
    "// ext_host/flutter/tool/embed_testext.py after rebuilding it.\n"
    "const String testExtensionApkBase64 =\n" + "\n".join(f"    '{line}'" for line in lines) + ";\n"
)
