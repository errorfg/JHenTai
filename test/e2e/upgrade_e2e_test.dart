@Tags(<String>['external'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/network/eh_igneous.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/cloud/s3_provider.dart';
import 'package:jhentai/src/service/eh_account_sync.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
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

/// A device of 8.1.1 upgraded: a copy of its database (never the database
/// itself) opened by this version, then synced with the test sync server
/// and the test bucket of test/e2e/real_sync_e2e.json. Its `upgrade.database`
/// names the database of 8.1.1 to copy.
void main() {
  final File configFile = File('test/e2e/real_sync_e2e.json');
  final Map<String, dynamic>? config = configFile.existsSync() ? jsonDecode(configFile.readAsStringSync()) as Map<String, dynamic> : null;
  final String? source = (config?['upgrade'] as Map?)?['database'] as String?;
  if (config == null || source == null || !File(source).existsSync()) {
    test('upgrade of a device of 8.1.1', () {}, skip: 'test/e2e/real_sync_e2e.json names no database of 8.1.1 (upgrade.database)');
    return;
  }
  final Map<String, dynamic> s3 = config['s3'] as Map<String, dynamic>;
  final Map<String, dynamic> server = config['server'] as Map<String, dynamic>;
  if (!(s3['bucket'] as String).endsWith('-dev') || !(server['url'] as String).contains('-dev')) {
    test('upgrade of a device of 8.1.1', () {}, skip: 'the test bucket and server must be ones named -dev');
    return;
  }

  late Directory temp;
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    HttpOverrides.global = null;
    ehSetting.nhentaiDomains.value = <String>['nhentai.net', 'nhentai.to'];
    temp = Directory.systemTemp.createTempSync('upgrade_e2e');
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test('a device of 8.1.1 upgrades: its database, its history, then sync with the test server and the test bucket', () async {
    final File copy = File(source).copySync('${temp.path}/db.sqlite');
    appDb = AppDb.forTesting(NativeDatabase(copy));
    localConfigService = LocalConfigService();
    historyService = HistoryService();
    pendingSyncTracker = PendingSyncTracker();
    readProgressService = ReadProgressService();
    jmFavoriteService = JmFavoriteService();
    ehAccountSync = EhAccountSync(
      jar: _MemoryJar(),
      fetchIgneous: ({required int ipbMemberId, required String ipbPassHash}) async => const IgneousRefresh(IgneousResult.noAccess),
    );

    final List<GalleryHistoryV2Data> before = await GalleryHistoryDao.selectAll();
    expect(await appDb.customSelect('pragma user_version').getSingle().then((r) => r.data.values.first), 26, reason: 'migrated from 25');
    await historyService.ensureMigrated();
    final List<GalleryHistoryV2Data> after = await GalleryHistoryDao.selectAll();
    expect(after.length, before.length, reason: 'no history row lost');
    int nh = 0, wn = 0;
    for (final GalleryHistoryV2Data row in after) {
      final GalleryUrl? url = GalleryUrl.tryParseStored((jsonDecode(row.jsonBody) as Map)['galleryUrl'] as String);
      if (url == null) {
        continue;
      }
      expect(row.gid, url.storageGid, reason: url.contentKey);
      nh += url.isNH ? 1 : 0;
      wn += url.isWN ? 1 : 0;
    }

    syncSetting = SyncSetting()
      ..enableSync.value = true
      ..enableHistory.value = false
      ..currentProvider.value = SyncService.serverProvider;
    final Stopwatch watch = Stopwatch()..start();
    SyncResult result = await SyncService(recordBackendFactory: () => HttpRecordBackend(url: server['url'] as String, token: server['token'] as String))
        .sync(types: CloudConfigTypeEnum.values);
    expect(result.success, isTrue, reason: result.message);
    final int toServer = watch.elapsedMilliseconds;
    expect((await GalleryHistoryDao.selectAll()).length, greaterThanOrEqualTo(after.length));

    syncSetting.currentProvider.value = 's3';
    watch.reset();
    result = await SyncService(
      providerFactory: (_) => S3Provider(
        endpoint: s3['endpoint'] as String,
        accessKey: s3['accessKey'] as String,
        secretKey: s3['secretKey'] as String,
        bucketName: s3['bucket'] as String,
        region: s3['region'] as String? ?? 'auto',
      ),
    ).sync(types: CloudConfigTypeEnum.values);
    expect(result.success, isTrue, reason: result.message);
    final int toBucket = watch.elapsedMilliseconds;
    final int progress = (await localConfigService.readWithAllSubKeys(configKey: ConfigEnum.readIndexRecord)).length;
    // ignore: avoid_print
    print('upgrade: ${after.length} history rows ($nh nhentai, $wn wnacg moved), $progress progress rows; '
        'server $toServer ms, bucket $toBucket ms');
    await appDb.close();
  });
}
