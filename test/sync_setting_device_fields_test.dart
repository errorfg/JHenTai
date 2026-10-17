import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/record_sync/record_adapters.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

/// Which way a device syncs, and whether it does, is its own choice: a sync
/// carries the other sync settings (addresses, keys) but not those.

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

class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

/// latest.json of another device; downloading it waits for [release].
class _SlowBucket implements CloudProvider {
  _SlowBucket(this.latest);

  String? latest;
  final Completer<void> release = Completer<void>();
  final Completer<void> downloading = Completer<void>();

  @override
  String get name => 'memory';

  @override
  Future<CloudFile?> getFileMetadata() async =>
      CloudFile(version: 'latest', modifiedTime: DateTime.now().toUtc(), size: latest!.length);

  @override
  Future<String?> download() async {
    downloading.complete();
    await release.future;
    return latest;
  }

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    latest = data;
    return CloudFile(version: 'latest', modifiedTime: DateTime.now().toUtc(), size: data.length);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _OneRecordServer implements RecordBackend {
  _OneRecordServer(this.record);

  final RemoteRecord record;

  @override
  Future<RecordServerInfo> info() async => const RecordServerInfo(protocol: 1, database: 'db-1');

  @override
  Future<void> push(List<RemoteRecord> records) async {}

  @override
  Future<RecordPage> pull({required int since, required String device, required int limit}) async =>
      since == 0 ? RecordPage(records: [record], next: 1, more: false) : const RecordPage(records: [], next: 1, more: false);
}

/// Sync settings of another device: on the bucket, with its own keys.
String _otherDevicesSettings() => jsonEncode({
      'currentProvider': 's3',
      'enableSync': true,
      'autoSync': false,
      's3Endpoint': 'https://storage.example.test',
      'syncServerUrl': 'https://sync.example.test',
      'syncServerToken': 'token-from-the-other-device',
    });

void main() {
  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    localConfigService = LocalConfigService();
    syncSetting = SyncSetting();
    await syncSetting.saveEnableSync(true);
    await syncSetting.saveAutoSync(true);
    await syncSetting.saveCurrentProvider('s3');
  });

  tearDown(() => appDb.close());

  test('switching to the sync server while a bucket sync is running stays switched', () async {
    final _SlowBucket bucket = _SlowBucket(jsonEncode([
      {
        'id': -1,
        'shareCode': 'local',
        'identificationCode': 'local',
        'type': CloudConfigTypeEnum.syncSetting.code,
        'version': '1.0.0',
        'config': _otherDevicesSettings(),
        'ctime': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      },
    ]));

    Future<SyncResult> running = SyncService(providerFactory: (_) => bucket).sync(types: const [CloudConfigTypeEnum.syncSetting]);
    await bucket.downloading.future;

    // The user picks the sync server meanwhile.
    await syncSetting.saveCurrentProvider(SyncService.serverProvider);
    bucket.release.complete();
    expect((await running).success, isTrue);

    expect(syncSetting.currentProvider.value, SyncService.serverProvider);
    expect(syncSetting.autoSync.value, isTrue);
    // The rest of the other device's settings did arrive.
    expect(syncSetting.s3Endpoint.value, 'https://storage.example.test');
    expect(syncSetting.syncServerUrl.value, 'https://sync.example.test');
    expect(jsonDecode((await localConfigService.read(configKey: ConfigEnum.syncSetting))!)['currentProvider'], SyncService.serverProvider);
  });

  test('sync settings taken from the sync server keep this device\'s choice of sync', () async {
    await syncSetting.saveCurrentProvider(SyncService.serverProvider);
    final _OneRecordServer server = _OneRecordServer(RemoteRecord(
      kind: 'syncSetting',
      key: SingleConfigRecords.key,
      value: _otherDevicesSettings(),
      updatedAt: SyncTimeUtil.format(DateTime.now().add(const Duration(hours: 1))),
      device: 'other',
      deleted: false,
    ));

    await RecordSyncEngine(adapters: defaultRecordAdapters().where((a) => a.kind == 'syncSetting').toList()).sync(server);

    expect(syncSetting.currentProvider.value, SyncService.serverProvider);
    expect(syncSetting.autoSync.value, isTrue);
    expect(syncSetting.s3Endpoint.value, 'https://storage.example.test');
    expect(syncSetting.syncServerToken.value, 'token-from-the-other-device');
  });
}
