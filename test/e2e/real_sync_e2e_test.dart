@Tags(<String>['external'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/dao/sync_record_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_igneous.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/eh_account_sync.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/record_sync/bucket_record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_adapters.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/eh_setting.dart';
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

/// Cookies kept in memory: the login of the real data is applied here, not
/// to the app's cookie store.
class _MemoryJar implements EhCookieJar {
  @override
  final List<Cookie> cookies = <Cookie>[];

  @override
  Future<void> store(List<Cookie> stored) async {
    cookies
      ..removeWhere((Cookie c) => stored.any((Cookie s) => s.name == c.name))
      ..addAll(stored);
  }

  @override
  Future<void> remove(List<String> names) async => cookies.removeWhere((Cookie c) => names.contains(c.name));

  @override
  Future<void> logout() async => cookies.clear();
}

/// A device of this version, new: its own database and services.
class _Device {
  _Device(this.provider);

  final String provider;
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final JmFavoriteService jm = JmFavoriteService();
  final _MemoryJar cookies = _MemoryJar();
  late final EhAccountSync account = EhAccountSync(
    jar: cookies,
    // ExHentai is not asked: the device of the test gets no igneous.
    fetchIgneous: ({required int ipbMemberId, required String ipbPassHash}) async => const IgneousRefresh(IgneousResult.noAccess),
  );
  late final SyncSetting settings = SyncSetting()
    ..enableSync.value = true
    ..autoSync.value = false
    ..enableHistory.value = false
    ..currentProvider.value = provider;

  void activate() {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    jmFavoriteService = jm;
    syncSetting = settings;
    ehAccountSync = account;
  }

  Future<void> sync({CloudProvider? bucket, RecordBackend? server}) async {
    activate();
    final SyncResult result = await SyncService(providerFactory: (_) => bucket, recordBackendFactory: () => server).sync(types: CloudConfigTypeEnum.values);
    expect(result.success, isTrue, reason: result.message);
  }

  Future<Set<int>> historyRows() async {
    activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }

  Future<Set<String>> progressKeys() async {
    activate();
    return (await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord)).map((r) => r.subConfigKey).toSet();
  }

  Future<Map<String, String?>> configs(List<ConfigEnum> keys) async {
    activate();
    return <String, String?>{for (final ConfigEnum key in keys) key.key: await localConfigService.read(configKey: key)};
  }
}

/// Sync of this version against a test bucket and a test sync server that
/// hold copies of real data synced by 8.1.1 (test/e2e/real_sync_e2e.json).
/// The bucket's records layout is cleared first; nothing else of it is
/// written. Never point this at the bucket or server in use.
void main() {
  final File configFile = File('test/e2e/real_sync_e2e.json');
  if (!configFile.existsSync()) {
    test('sync with real data', () {}, skip: 'test/e2e/real_sync_e2e.json is absent');
    return;
  }
  final Map<String, dynamic> config = jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic>;
  final Map<String, dynamic> s3 = config['s3'] as Map<String, dynamic>;
  final Map<String, dynamic> server = config['server'] as Map<String, dynamic>;
  if (!(s3['bucket'] as String).endsWith('-dev') || !(server['url'] as String).contains('-dev')) {
    test('sync with real data', () {}, skip: 'the test bucket and server must be ones named -dev');
    return;
  }
  S3Provider bucket() => S3Provider(
        endpoint: s3['endpoint'] as String,
        accessKey: s3['accessKey'] as String,
        secretKey: s3['secretKey'] as String,
        bucketName: s3['bucket'] as String,
        region: s3['region'] as String? ?? 'auto',
      );
  RecordBackend serverBackend() => HttpRecordBackend(url: server['url'] as String, token: server['token'] as String);

  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    HttpOverrides.global = null;
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
  });

  test('a bucket synced by 8.1.1: the first device of this version takes it over, the next gets the same, and the files of 8.1.1 stay as they were', () async {
    final S3Provider provider = bucket();
    for (final RemoteObjectInfo object in await provider.listRawObjects(BucketRecordBackend.root)) {
      await provider.deleteRawObject(object.key);
    }
    final Map<String, DateTime?> before = <String, DateTime?>{
      for (final RemoteObjectInfo o in await provider.listRawObjects('')) if (!o.key.startsWith('records/')) o.key: o.modifiedTime,
    };

    final _Device phone = _Device('s3'), tablet = _Device('s3');
    final Stopwatch watch = Stopwatch()..start();
    await phone.sync(bucket: provider);
    final Duration takeOver = watch.elapsed;
    watch.reset();
    await tablet.sync(bucket: provider);
    final Duration join = watch.elapsed;

    final Set<int> history = await phone.historyRows();
    expect(history, isNotEmpty);
    expect(await tablet.historyRows(), history);
    expect(await tablet.progressKeys(), await phone.progressKeys());
    final List<ConfigEnum> lists = <ConfigEnum>[ConfigEnum.nhentaiFavorite, ConfigEnum.jmFavorite, ConfigEnum.wnacgFavorite, ConfigEnum.tachiFavorite, ConfigEnum.quickSearch];
    final Map<String, String?> phoneLists = await phone.configs(lists), tabletLists = await tablet.configs(lists);
    for (final ConfigEnum key in lists) {
      final dynamic a = phoneLists[key.key] == null ? null : jsonDecode(phoneLists[key.key]!), b = tabletLists[key.key] == null ? null : jsonDecode(tabletLists[key.key]!);
      expect(b is List ? b.length : (b as Map?)?.length, a is List ? a.length : (a as Map?)?.length, reason: key.key);
    }

    final Map<String, DateTime?> after = <String, DateTime?>{
      for (final RemoteObjectInfo o in await provider.listRawObjects('')) if (!o.key.startsWith('records/')) o.key: o.modifiedTime,
    };
    expect(after, before, reason: 'the files of 8.1.1 are not written');
    // ignore: avoid_print
    print('bucket: ${history.length} history rows, ${(await phone.progressKeys()).length} progress rows; '
        'taken over in ${takeOver.inMilliseconds} ms, joined in ${join.inMilliseconds} ms');
  });

  test('records synced by 8.1.1 through a sync server: history, progress and Tachiyomi repositories reach a device of this version', () async {
    final _Device desktop = _Device(SyncService.serverProvider);
    final Stopwatch watch = Stopwatch()..start();
    await desktop.sync(server: serverBackend());

    desktop.activate();
    final List<SyncRecordData> legacy = (await SyncRecordDao.selectByKind('history')).where((r) => !r.deleted).toList();
    final Map<String, int> bySite = <String, int>{};
    for (final SyncRecordData record in legacy) {
      final String? key = GalleryHistoryRecords.keyOf(record.value!);
      if (key != null) {
        bySite.update(key.contains(':') ? key.split(':').first : 'jm or tachi', (int n) => n + 1, ifAbsent: () => 1);
      }
    }
    final Set<int> rows = await desktop.historyRows();
    final int readable = bySite.values.fold(0, (int a, int b) => a + b);
    expect(rows.length, greaterThanOrEqualTo(readable), reason: 'every readable history record of 8.1.1 is a row');
    expect(rows.where((int gid) => gid >= GalleryUrl.nhStorageOffset && gid < GalleryUrl.wnStorageOffset).length, bySite['nh'] ?? 0);
    expect(rows.where((int gid) => gid >= GalleryUrl.wnStorageOffset && gid < GalleryUrl.jmGidOffset).length, bySite['wn'] ?? 0);

    final List<SyncRecordData> progress = (await SyncRecordDao.selectByKind('readProgress')).where((r) => !r.deleted).toList();
    expect((await desktop.progressKeys()).containsAll(progress.map((r) => r.key)), isTrue);

    final List<SyncRecordData> extensionList = await SyncRecordDao.selectByKind('tachiExtensionList');
    if (extensionList.isNotEmpty) {
      final List<dynamic> repos = (jsonDecode(extensionList.single.value!) as Map)['repos'] as List? ?? <dynamic>[];
      final String? stored = (await desktop.configs(<ConfigEnum>[ConfigEnum.tachiExtensionSetting]))[ConfigEnum.tachiExtensionSetting.key];
      expect(((stored == null ? <String, dynamic>{} : jsonDecode(stored)) as Map)['repos'] ?? <dynamic>[], containsAll(repos));
    }
    // ignore: avoid_print
    print('server: ${legacy.length} history records of 8.1.1 ($bySite), ${rows.length} rows, '
        '${progress.length} progress records, in ${watch.elapsedMilliseconds} ms');
  });
}
