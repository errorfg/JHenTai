import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/utils/version_util.dart';

void main() {
  test('a fix release that bumps only the build number is newer', () {
    expect(compareVersion('v8.0.28+341', 'v8.0.28+342'), -1);
    expect(compareVersion('v8.0.28+342', 'v8.0.28+342'), 0);
    expect(compareVersion('v8.0.28+342', 'v8.0.28+341'), 1);
  });

  test('the version number decides before the build number', () {
    expect(compareVersion('v8.0.28+400', 'v8.0.29+1'), -1);
    expect(compareVersion('v8.0.16+334', 'v8.0.28+341'), -1);
  });

  test('a side without a build number compares by version only', () {
    expect(compareVersion('v8.0.28', 'v8.0.28+342'), 0);
    expect(compareVersion('v8.0.27', 'v8.0.28+342'), -1);
  });
}
