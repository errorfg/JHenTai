import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/dao/sync_record_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_block_rule_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/quick_search_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/search_history_service.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/sync_setting.dart';
import 'package:jhentai/src/utils/sync_time_util.dart';

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

/// Runs JSON work inline; the app's isolate is not started in tests.
class _InlineIsolateService extends IsolateService {
  @override
  Future<String> jsonEncodeAsync(Object object) async => jsonEncode(object);

  @override
  Future<dynamic> jsonDecodeAsync(String string) async => jsonDecode(string);
}

class _Stored {
  final RemoteRecord record;
  final int seq;

  _Stored(this.record, this.seq);
}

/// The sync server in memory, with the rules of sync_server/src/index.ts.
/// Pulls fail once [pullsBeforeFailure] reaches zero.
class _MemoryServer implements RecordBackend {
  _MemoryServer(this.database);

  final String database;
  final Map<String, _Stored> stored = {};
  int seq = 0;
  int pulls = 0;
  int pushedRecords = 0;
  int? pullsBeforeFailure;

  @override
  Future<RecordServerInfo> info() async => RecordServerInfo(protocol: 1, database: database);

  @override
  Future<void> push(List<RemoteRecord> records) async {
    pushedRecords += records.length;
    for (RemoteRecord record in records) {
      String id = '${record.kind}\u0000${record.key}';
      _Stored? current = stored[id];
      if (current == null ||
          compareVersions(record.updatedAt, record.device, current.record.updatedAt, current.record.device) > 0) {
        stored[id] = _Stored(record, ++seq);
      }
    }
  }

  @override
  Future<RecordPage> pull({required int since, required String device, required int limit}) async {
    if (pullsBeforeFailure != null) {
      if (pullsBeforeFailure == 0) {
        throw RecordServerException(null, 'connection reset');
      }
      pullsBeforeFailure = pullsBeforeFailure! - 1;
    }
    pulls++;
    List<_Stored> page = (stored.values.where((s) => s.seq > since && s.record.device != device).toList()
          ..sort((a, b) => a.seq.compareTo(b.seq)))
        .take(limit)
        .toList();
    bool more = page.length == limit;
    return RecordPage(
      records: page.map((s) => s.record).toList(),
      next: more ? page.last.seq : (seq > since ? seq : since),
      more: more,
    );
  }

  RemoteRecord? record(String kind, String key) => stored['$kind\u0000$key']?.record;
}

/// One device: its database and the services that live on it.
class _Device {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final JmFavoriteService jm = JmFavoriteService();
  final QuickSearchService quick = QuickSearchService();
  final SearchHistoryService search = SearchHistoryService();
  final LocalBlockRuleService rules = LocalBlockRuleService();
  final KomgaSetting komga = KomgaSetting();
  final SyncSetting settings = SyncSetting();
  bool _initialized = false;

  Future<void> activate() async {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    jmFavoriteService = jm;
    quickSearchService = quick;
    searchHistoryService = search;
    localBlockRuleService = rules;
    komgaSetting = komga;
    syncSetting = settings;
    if (!_initialized) {
      _initialized = true;
      await rules.doInitBean();
    }
  }

  Future<RecordSyncResult> sync(_MemoryServer server) async {
    await activate();
    return RecordSyncEngine().sync(server);
  }

  Future<Set<int>> historyGids() async {
    await activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }

  /// JM favorites: album id to category.
  Future<Map<int, int?>> favorites() async {
    await activate();
    return {
      for (Gallery g in jm.getDisplayFavorites()) g.gid - GalleryUrl.jmGidOffset: g.favoriteTagIndex,
    };
  }

  Future<List<String>> searchHistory() async {
    await activate();
    return search.histories.map((h) => h.rawKeyword).toList();
  }
}

GalleryHistoryModel _entry(int gid) => GalleryHistoryModel(
      galleryUrl: GalleryUrl(isEH: true, gid: gid, token: 't${gid.toString().padLeft(9, '0')}'),
      title: 'Gallery $gid',
      category: 'Manga',
      coverUrl: 'https://cdn.example.test/$gid.jpg',
      pageCount: 20,
      rating: 0,
      language: '',
      uploader: '',
      publishTime: '',
      isExpunged: false,
      tags: const <String>[],
    );

Gallery _jmGallery(int id) => Gallery(
      galleryUrl: GalleryUrl.jm(id),
      title: 'JM $id',
      category: 'Manga',
      cover: GalleryImage(url: 'https://example.test/cover.jpg'),
      pageCount: 10,
      rating: 0,
      hasRated: false,
      language: null,
      uploader: null,
      publishTime: '2026-10-01 10:00',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );

/// So that two changes made one after the other never share a timestamp.
Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 2));

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
  });

  test('two devices end up with each other\'s data, and a deletion on one stays a deletion on both', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    final _Device desktop = _Device();

    await phone.activate();
    await historyService.record(_entry(1));
    await historyService.record(_entry(2));
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0);
    await jmFavoriteService.addFavorite(_jmGallery(102), favoriteCategoryIndex: 1);
    quickSearchService.quickSearchConfigs['Long reads'] = SearchConfig(keyword: 'pages:>100');
    await quickSearchService.saveBeanConfig();
    await searchHistoryService.writeHistory('first');
    await searchHistoryService.writeHistory('second');
    await localBlockRuleService.replaceBlockRulesByGroup('group-1', [
      LocalBlockRule(
        target: LocalBlockTargetEnum.gallery,
        attribute: LocalBlockAttributeEnum.title,
        pattern: LocalBlockPatternEnum.like,
        expression: 'spoiler',
      ),
    ]);
    await localConfigService.write(configKey: ConfigEnum.komgaSetting, value: '{"servers":["https://komga.example.test"]}');
    await phone.sync(server);

    await desktop.activate();
    await historyService.record(_entry(3));
    await jmFavoriteService.addFavorite(_jmGallery(103), favoriteCategoryIndex: 2);
    await desktop.sync(server);
    await phone.sync(server);

    for (final _Device device in [phone, desktop]) {
      expect(await device.historyGids(), {1, 2, 3});
      expect(await device.favorites(), {101: 0, 102: 1, 103: 2});
      expect(quickSearchService.quickSearchConfigs.keys, ['Long reads']);
      expect(quickSearchService.quickSearchConfigs['Long reads']!.keyword, 'pages:>100');
      expect(await device.searchHistory(), ['second', 'first']);
      expect((await localBlockRuleService.getBlockRules()).map((r) => (r.groupId, r.expression)), [('group-1', 'spoiler')]);
      expect(await localConfigService.read(configKey: ConfigEnum.komgaSetting), '{"servers":["https://komga.example.test"]}');
    }

    // The phone removes a favorite and a history entry.
    await phone.activate();
    await jmFavoriteService.removeFavorite(_jmGallery(102).gid);
    await historyService.delete(1);
    await phone.sync(server);
    await desktop.sync(server);
    expect(await desktop.favorites(), {101: 0, 103: 2});
    expect(await desktop.historyGids(), {2, 3});

    // More syncs either way bring nothing back.
    await desktop.sync(server);
    await phone.sync(server);
    await desktop.sync(server);
    for (final _Device device in [phone, desktop]) {
      expect(await device.favorites(), {101: 0, 103: 2});
      expect(await device.historyGids(), {2, 3});
    }

    // Added again later, the favorite is back everywhere.
    await _tick();
    await desktop.activate();
    await jmFavoriteService.addFavorite(_jmGallery(102), favoriteCategoryIndex: 4);
    await desktop.sync(server);
    await phone.sync(server);
    expect(await phone.favorites(), {101: 0, 102: 4, 103: 2});
  });

  test('devices that already hold the same data push nothing more once they have met', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    final _Device desktop = _Device();
    // Both synced through a bucket before: the same rows, the same favorites.
    for (final _Device device in [phone, desktop]) {
      await device.activate();
      await historyService.recordAt(_entry(1), '2026-10-01T10:00:00.000000Z');
      await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0, favoritedTime: DateTime.utc(2026, 10, 1));
      quickSearchService.quickSearchConfigs['Long reads'] = SearchConfig(keyword: 'pages:>100');
      await quickSearchService.saveBeanConfig();
    }

    await phone.sync(server);
    int afterPhone = server.pushedRecords;
    await desktop.sync(server);
    expect(server.pushedRecords, afterPhone, reason: 'the desktop holds nothing the server lacks');

    await phone.sync(server);
    await desktop.sync(server);
    await phone.sync(server);
    expect(server.pushedRecords, afterPhone);
  });

  test('an item changed on both devices takes the later change on both', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    final _Device desktop = _Device();
    await phone.activate();
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0);
    await phone.sync(server);
    await desktop.sync(server);

    await phone.activate();
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 3);
    await _tick();
    await desktop.activate();
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 5);

    // The earlier change reaches the server first; the later one still wins.
    await phone.sync(server);
    await desktop.sync(server);
    await phone.sync(server);
    expect(await phone.favorites(), {101: 5});
    expect(await desktop.favorites(), {101: 5});
  });

  test('a history entry read again after another device deleted it stays', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    final _Device desktop = _Device();
    await phone.activate();
    await historyService.record(_entry(1));
    await phone.sync(server);
    await desktop.sync(server);

    await phone.activate();
    await historyService.delete(1);
    await _tick();
    await desktop.activate();
    await historyService.record(_entry(1));

    await phone.sync(server);
    await desktop.sync(server);
    await phone.sync(server);
    expect(await phone.historyGids(), {1});
    expect(await desktop.historyGids(), {1});
  });

  test('a keyword searched again moves to the front on the other device, as one record', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    final _Device desktop = _Device();
    await phone.activate();
    for (final String keyword in ['a', 'b', 'c']) {
      await searchHistoryService.writeHistory(keyword);
      await _tick();
    }
    await phone.sync(server);
    await desktop.sync(server);
    expect(await desktop.searchHistory(), ['c', 'b', 'a']);

    await phone.activate();
    await searchHistoryService.writeHistory('a');
    int before = server.pushedRecords;
    await phone.sync(server);
    expect(server.pushedRecords - before, 1);
    await desktop.sync(server);
    expect(await desktop.searchHistory(), ['a', 'c', 'b']);
  });

  test('records of a kind this version does not know are kept, and go to a new database with the rest', () async {
    final _MemoryServer first = _MemoryServer('db-1');
    await first.push([
      RemoteRecord(
        kind: 'laterKind',
        key: 'k',
        value: '{"from":"a later version"}',
        updatedAt: SyncTimeUtil.nowIso(),
        device: 'other',
        deleted: false,
      ),
    ]);
    final _Device phone = _Device();
    await phone.activate();
    await historyService.record(_entry(1));
    await phone.sync(first);
    expect((await SyncRecordDao.selectByKind('laterKind')).single.value, '{"from":"a later version"}');

    // The server's database is replaced: everything the phone knows goes up.
    final _MemoryServer second = _MemoryServer('db-2');
    await phone.sync(second);
    expect(second.record('laterKind', 'k')!.device, 'other');
    expect(second.record('history', '1'), isNotNull);
  });

  test('a pull cut short goes on from where it stopped', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    String time = SyncTimeUtil.nowIso();
    await server.push([
      for (int gid = 1; gid <= 450; gid++)
        RemoteRecord(
          kind: 'history',
          key: '$gid',
          value: jsonEncode(_entry(gid)),
          updatedAt: time,
          device: 'other',
          deleted: false,
        ),
    ]);

    final _Device desktop = _Device();
    server.pullsBeforeFailure = 2;
    await expectLater(desktop.sync(server), throwsA(isA<RecordServerException>()));
    await desktop.activate();
    expect((await SyncRecordDao.selectByKind('history')).length, 2 * RecordSyncEngine.pullLimit);

    server.pullsBeforeFailure = null;
    server.pulls = 0;
    RecordSyncResult result = await desktop.sync(server);
    expect(result.pulled, 450 - 2 * RecordSyncEngine.pullLimit);
    expect(server.pulls, 1);
    expect(await desktop.historyGids(), {for (int gid = 1; gid <= 450; gid++) gid});
  });

  test('the sync service syncs through the server when the server is chosen', () async {
    final _MemoryServer server = _MemoryServer('db-1');
    final _Device phone = _Device();
    await phone.activate();
    syncSetting.currentProvider.value = SyncService.serverProvider;
    await historyService.record(_entry(7));

    final SyncService service = SyncService(recordBackendFactory: () => server);
    SyncResult result = await service.sync(types: const [CloudConfigTypeEnum.history]);
    expect(result.success, isTrue, reason: result.message);
    expect(server.record('history', '7'), isNotNull);
  });
}
