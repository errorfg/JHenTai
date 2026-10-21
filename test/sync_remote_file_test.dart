import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/record_sync/bucket_record_backend.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

import 'memory_bucket.dart';

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

/// The records pushed to [bucket], from its packs.
List<Map<String, dynamic>> _records(MemoryBucket bucket) => <Map<String, dynamic>>[
      for (final MapEntry<String, ({List<int> bytes, DateTime modified})> e in bucket.objects.entries)
        if (e.key.startsWith(BucketRecordBackend.packsPrefix))
          ...((jsonDecode(utf8.decode(gzip.decode(e.value.bytes))) as Map)['records'] as List).cast<Map<String, dynamic>>(),
    ];

/// Who took over what earlier versions synced in [bucket], if anyone did.
String? _legacyTakenBy(MemoryBucket bucket) {
  final List<int>? manifest = bucket.objects[BucketRecordBackend.manifestKey]?.bytes;
  return manifest == null ? null : BucketManifest.fromJson(jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>).legacyDevice;
}

Map<String, dynamic> _entry(int type, String config, {int ctime = 1000}) =>
    <String, dynamic>{
      'id': -1,
      'shareCode': 'local',
      'identificationCode': 'local',
      'type': type,
      'version': '1.0.0',
      'config': config,
      'ctime': ctime,
    };

const String _komgaPayload =
    '{"serverUrl":"http://komga:25600","username":"reader","password":"",'
    '"apiKey":"key","connectionId":"64c8f6b0-bfaf-11f1-a76c-531c4f3693ea"}';

void main() {
  late LogService originalLog;
  late IsolateService originalIsolateService;
  late SyncSetting originalSyncSetting;

  setUp(() async {
    originalLog = log;
    originalIsolateService = isolateService;
    originalSyncSetting = syncSetting;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    syncSetting = SyncSetting()
      ..enableSync.value = true
      ..autoSync.value = true
      ..enableHistory.value = false;
    appDb = AppDb.forTesting(NativeDatabase.memory());
    await komgaSetting.save(
      serverUrl: '',
      username: '',
      password: '',
      apiKey: '',
    );
    await localConfigService.delete(configKey: ConfigEnum.komgaSetting);
  });

  tearDown(() async {
    await appDb.close();
    log = originalLog;
    isolateService = originalIsolateService;
    syncSetting = originalSyncSetting;
  });

  SyncService serviceFor(MemoryBucket bucket) => SyncService(providerFactory: (_) => bucket);

  test('what earlier versions synced in the bucket is taken over once, and their files are not written', () async {
    final String latest = jsonEncode(<dynamic>[_entry(9, _komgaPayload), _entry(99, '{"newer":true}')]);
    final MemoryBucket bucket = MemoryBucket(latest: latest);

    final SyncResult result = await serviceFor(bucket).sync(types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting]);

    expect(result.success, isTrue, reason: result.message);
    expect(komgaSetting.apiKey.value, 'key');
    expect(_legacyTakenBy(bucket), isNotNull);
    expect(bucket.latest, latest);
    expect(bucket.writesOutsideRecords, isEmpty);
    expect(_records(bucket).where((r) => r['kind'] == 'komgaSetting'), hasLength(1));

    // A device of an earlier version writes latest.json later: not taken.
    bucket.latest = jsonEncode(<dynamic>[_entry(9, _komgaPayload.replaceFirst('"key"', '"later"'), ctime: DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch)]);
    expect((await serviceFor(bucket).sync(types: CloudConfigTypeEnum.values)).success, isTrue);
    expect(komgaSetting.apiKey.value, 'key');
    expect(bucket.writesOutsideRecords, isEmpty);
  });

  for (final ({String name, void Function(MemoryBucket) breaks}) broken in <({String name, void Function(MemoryBucket) breaks})>[
    (name: 'a failed download', breaks: (MemoryBucket b) => b.downloadError = Exception('connection reset')),
    (name: 'a read miss on a file that is there', breaks: (MemoryBucket b) => b.readMisses = true),
    (name: 'a file that can not be read', breaks: (MemoryBucket b) => b.latest = '{"truncated":'),
  ]) {
    test('${broken.name} of latest.json fails the sync, nothing goes up, and the takeover is tried again', () async {
      final MemoryBucket bucket = MemoryBucket(latest: jsonEncode(<dynamic>[_entry(9, _komgaPayload)]));
      broken.breaks(bucket);
      await komgaSetting.save(serverUrl: 'http://other', username: 'local', password: 'p', apiKey: '');

      expect((await serviceFor(bucket).sync(types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting])).success, isFalse);
      expect(_records(bucket), isEmpty);
      expect(_legacyTakenBy(bucket), isNull);
      expect(komgaSetting.serverUrl.value, 'http://other');

      bucket
        ..downloadError = null
        ..readMisses = false
        ..latest = jsonEncode(<dynamic>[_entry(9, _komgaPayload)]);
      expect((await serviceFor(bucket).sync(types: CloudConfigTypeEnum.values)).success, isTrue);
      expect(_legacyTakenBy(bucket), isNotNull);
    });
  }

  test('a bucket without files of earlier versions starts the records with this device\'s data', () async {
    final MemoryBucket bucket = MemoryBucket();
    await komgaSetting.save(serverUrl: 'http://komga:25600', username: 'reader', password: 'p', apiKey: '');

    final SyncResult result = await serviceFor(bucket).sync(types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting]);

    expect(result.success, isTrue, reason: result.message);
    expect(_records(bucket).where((r) => r['kind'] == 'komgaSetting'), hasLength(1));
    expect(_legacyTakenBy(bucket), isNotNull);
    expect(bucket.writesOutsideRecords, isEmpty);
  });

  test('a settings sync requested during another sync runs after it', () async {
    final Completer<SyncResult> first = Completer<SyncResult>();
    final List<List<CloudConfigTypeEnum>> calls = <List<CloudConfigTypeEnum>>[];
    final SyncService service = SyncService(
      executeSync: ({required types, providerName, onProgress}) {
        calls.add(types);
        return calls.length == 1
            ? first.future
            : Future<SyncResult>.value(
                SyncResult(success: true, message: 'ok', statistics: {}),
              );
      },
    );

    final Future<SyncResult> running = service.sync(
      types: CloudConfigTypeEnum.values,
    );
    final Future<SyncResult> change = service.syncAfterLocalChange(
      types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, hasLength(1));

    first.complete(SyncResult(success: true, message: 'ok', statistics: {}));
    await running;

    expect((await change).success, isTrue);
    expect(calls, <List<CloudConfigTypeEnum>>[
      CloudConfigTypeEnum.values,
      const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
    ]);
  });
}
