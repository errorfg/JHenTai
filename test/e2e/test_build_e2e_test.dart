@Tags(<String>['external'])
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/setting/test_build.dart';

class _SilentLogService extends LogService {
  @override
  void trace(Object msg, [bool withStack = false]) {}
  @override
  void debug(Object msg, [bool withStack = false]) {}
  @override
  void info(Object msg, [bool withStack = false]) {}
  @override
  void warning(Object msg, [Object? error, bool withStack = false]) {}
  @override
  void error(Object msg, [Object? error, StackTrace? stackTrace]) {}
}

/// A test build keeps to its test bucket and test sync server. Run with what
/// a test build is built with: flutter test --dart-define-from-file=<file>.
void main() {
  if (!TestBuild.on) {
    test('test build', () {}, skip: 'not built as a test build (--dart-define-from-file)');
    return;
  }

  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    localConfigService = LocalConfigService();
  });

  tearDown(() => appDb.close());

  test('settings imported or synced from the bucket in use do not move a test build off its test ones', () async {
    final SyncSetting setting = SyncSetting();
    expect((setting.s3BucketName.value, setting.syncServerUrl.value), (TestBuild.s3Bucket, TestBuild.serverUrl));

    setting.applyBeanConfig(jsonEncode(<String, Object>{
      'currentProvider': 'webdav',
      's3BucketName': 'jhentai-sync',
      's3Endpoint': 'account.r2.cloudflarestorage.com',
      'syncServerUrl': 'https://sync.example.com',
      'syncServerToken': 'token in use',
    }));
    expect(setting.s3BucketName.value, TestBuild.s3Bucket);
    expect(setting.s3Endpoint.value, TestBuild.s3Endpoint);
    expect(setting.syncServerUrl.value, TestBuild.serverUrl);
    expect(setting.syncServerToken.value, TestBuild.serverToken);
    expect(setting.currentProvider.value, 's3');
  });

  test('a sync that would go elsewhere is refused', () async {
    syncSetting = SyncSetting()..enableSync.value = true;
    syncSetting.s3BucketName.value = 'jhentai-sync';
    final SyncResult result = await SyncService(providerFactory: (_) => throw StateError('no provider is made')).sync(types: CloudConfigTypeEnum.values, providerName: 's3');
    expect(result.success, isFalse);
    expect(result.message, contains('test'));
  });
}
