import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

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

/// In-memory stand-in for the whole-file part of a cloud provider.
class _FakeProvider implements CloudProvider {
  _FakeProvider({this.latest, this.downloadError, this.readMisses = false});

  String? latest;
  Object? downloadError;

  /// Download reports a miss although the file exists, as the S3 provider
  /// does for any S3-level read error.
  bool readMisses;
  final List<String> uploads = <String>[];

  @override
  String get name => 'fake';

  @override
  Future<String?> download() async {
    if (downloadError != null) {
      throw downloadError!;
    }
    return readMisses ? null : latest;
  }

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    uploads.add(data);
    latest = data;
    return CloudFile(
      version: 'latest',
      modifiedTime: DateTime.now(),
      size: data.length,
    );
  }

  @override
  Future<CloudFile?> getFileMetadata() async => latest == null
      ? null
      : CloudFile(
          version: 'latest',
          modifiedTime: DateTime.utc(2026, 10, 4, 4, 52, 29),
          size: latest!.length,
        );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
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

List<int> _types(String json) =>
    (jsonDecode(json) as List).map((e) => e['type'] as int).toList();

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

  SyncService serviceFor(_FakeProvider provider) =>
      SyncService(providerFactory: (_) => provider);

  test(
    'entries written by a newer client do not hide the rest of the file',
    () async {
      final Map<String, dynamic> newer = _entry(99, '{"newer":true}');
      final _FakeProvider provider = _FakeProvider(
        latest: jsonEncode(<dynamic>[_entry(9, _komgaPayload), newer]),
      );

      final SyncResult result = await serviceFor(provider).sync(
        types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
      );

      expect(result.success, isTrue, reason: result.message);
      expect(komgaSetting.isConfigured, isTrue);
      expect(komgaSetting.apiKey.value, 'key');
      expect(_types(provider.latest!), containsAll(<int>[9, 99]));
      expect(
        (jsonDecode(provider.latest!) as List).firstWhere(
          (e) => e['type'] == 99,
        ),
        newer,
      );
    },
  );

  test('a partial sync keeps every other type in the remote file', () async {
    final _FakeProvider provider = _FakeProvider(
      latest: jsonEncode(<dynamic>[_entry(3, '[]'), _entry(9, _komgaPayload)]),
    );
    await localConfigService.write(
      configKey: ConfigEnum.eh2telegraphSetting,
      value: '{"endpoint":"http://bot","token":"t"}',
    );

    final SyncResult result = await serviceFor(provider).sync(
      types: const <CloudConfigTypeEnum>[
        CloudConfigTypeEnum.eh2telegraphSetting,
      ],
    );

    expect(result.success, isTrue, reason: result.message);
    expect(provider.uploads, hasLength(1));
    expect(_types(provider.latest!), <int>[3, 9, 11]);
  });

  test('a failed download aborts the sync without uploading', () async {
    final _FakeProvider provider = _FakeProvider(
      latest: jsonEncode(<dynamic>[_entry(9, _komgaPayload)]),
      downloadError: Exception('connection reset'),
    );
    await komgaSetting.save(
      serverUrl: 'http://other',
      username: 'local',
      password: 'p',
      apiKey: '',
    );

    final SyncResult result = await serviceFor(provider).sync(
      types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
    );

    expect(result.success, isFalse);
    expect(provider.uploads, isEmpty);
  });

  test('a read miss on an existing file aborts the sync', () async {
    final _FakeProvider provider = _FakeProvider(
      latest: jsonEncode(<dynamic>[_entry(9, _komgaPayload)]),
      readMisses: true,
    );
    await komgaSetting.save(
      serverUrl: 'http://other',
      username: 'local',
      password: 'p',
      apiKey: '',
    );

    final SyncResult result = await serviceFor(provider).sync(
      types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
    );

    expect(result.success, isFalse);
    expect(provider.uploads, isEmpty);
  });

  test('an unreadable remote file aborts the sync without uploading', () async {
    final _FakeProvider provider = _FakeProvider(latest: '{"truncated":');
    await komgaSetting.save(
      serverUrl: 'http://other',
      username: 'local',
      password: 'p',
      apiKey: '',
    );

    final SyncResult result = await serviceFor(provider).sync(
      types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
    );

    expect(result.success, isFalse);
    expect(provider.uploads, isEmpty);
  });

  test(
    'a missing remote file is a first sync and uploads local data',
    () async {
      final _FakeProvider provider = _FakeProvider();
      await komgaSetting.save(
        serverUrl: 'http://komga:25600',
        username: 'reader',
        password: 'p',
        apiKey: '',
      );

      final SyncResult result = await serviceFor(provider).sync(
        types: const <CloudConfigTypeEnum>[CloudConfigTypeEnum.komgaSetting],
      );

      expect(result.success, isTrue, reason: result.message);
      expect(_types(provider.latest!), <int>[9]);
    },
  );

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
