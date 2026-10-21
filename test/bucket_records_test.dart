import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/search_config.dart';
import 'package:jhentai/src/service/cloud/hot_data_sync_engine.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/record_sync/bucket_record_backend.dart';
import 'package:jhentai/src/service/record_sync/record_sync_engine.dart';
import 'package:jhentai/src/service/sync_service.dart';
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

/// One device: its database and the services that keep state of their own.
class _Device {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final JmFavoriteService jm = JmFavoriteService();
  final SyncSetting settings = SyncSetting()
    ..enableSync.value = true
    ..autoSync.value = true
    ..enableHistory.value = false
    ..currentProvider.value = 's3';

  void activate() {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    jmFavoriteService = jm;
    syncSetting = settings;
  }

  SyncService service(MemoryBucket bucket) => SyncService(providerFactory: (_) => bucket);

  Future<void> sync(MemoryBucket bucket) async {
    activate();
    final SyncResult result = await service(bucket).sync(types: CloudConfigTypeEnum.values);
    expect(result.success, isTrue, reason: result.message);
  }

  Future<Set<int>> historyGids() async {
    activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }

  Future<int> readProgress(String key) async {
    activate();
    return progress.getReadProgressByKey(key);
  }

  Set<int> favorites() {
    activate();
    return jm.getDisplayFavorites().map((g) => g.jmId).toSet();
  }

  /// Quick searches, by name: the keyword of each.
  Future<Map<String, String?>> quickSearches() async {
    activate();
    final String? raw = await localConfigService.read(configKey: ConfigEnum.quickSearch);
    return <String, String?>{
      for (final MapEntry<String, dynamic> e in ((raw == null ? <String, dynamic>{} : jsonDecode(raw)) as Map<String, dynamic>).entries)
        e.key: (e.value as Map)['keyword'] as String?,
    };
  }

  Future<void> setQuickSearches(Map<String, String> keywords) async {
    activate();
    await localConfigService.write(configKey: ConfigEnum.quickSearch, value: _quickSearchJson(keywords));
  }
}

String _quickSearchJson(Map<String, String> keywords) => jsonEncode(<String, dynamic>{
      for (final MapEntry<String, String> e in keywords.entries) e.key: SearchConfig(keyword: e.value).toJson(),
    });

extension on Gallery {
  int get jmId => galleryUrl.jmChapterId;
}

GalleryHistoryModel _history(int gid) => GalleryHistoryModel(
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

Gallery _jm(int id) => Gallery(
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

/// An entry of latest.json of earlier versions.
Map<String, dynamic> _entry(CloudConfigTypeEnum type, String config, DateTime ctime) => <String, dynamic>{
      'id': -1,
      'shareCode': 'local',
      'identificationCode': 'local',
      'type': type.code,
      'version': '1.0.0',
      'config': config,
      'ctime': ctime.millisecondsSinceEpoch,
    };

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
  });

  test('changes and deletions travel between devices through a bucket', () async {
    final MemoryBucket bucket = MemoryBucket();
    final _Device phone = _Device(), tablet = _Device();

    phone.activate();
    await historyService.record(_history(1));
    await historyService.record(_history(2));
    await readProgressService.updateReadProgress('1', 3);
    await jmFavoriteService.addFavorite(_jm(101), favoriteCategoryIndex: 0);
    await phone.setQuickSearches(<String, String>{'a': 'from the phone'});
    await phone.sync(bucket);
    await tablet.sync(bucket);
    expect(await tablet.historyGids(), <int>{1, 2});
    expect(await tablet.readProgress('1'), 3);
    expect(tablet.favorites(), <int>{101});
    expect(await tablet.quickSearches(), <String, String?>{'a': 'from the phone'});

    tablet.activate();
    await historyService.deleteGids(<int>[2]);
    await readProgressService.updateReadProgress('1', 9);
    await jmFavoriteService.removeFavorite(_jm(101).gid);
    await tablet.setQuickSearches(<String, String>{'b': 'from the tablet'});
    await tablet.sync(bucket);
    await phone.sync(bucket);

    expect(await phone.historyGids(), <int>{1});
    expect(await phone.readProgress('1'), 9);
    expect(phone.favorites(), isEmpty);
    expect(await phone.quickSearches(), <String, String?>{'b': 'from the tablet'});
    expect(bucket.writesOutsideRecords, isEmpty);
  });

  test('what an earlier version synced is taken over once; a device of it upgrading later does not undo newer changes', () async {
    final MemoryBucket bucket = MemoryBucket();

    // Synced by 8.1.1: history and progress in its op packs, quick searches
    // in latest.json.
    final _Device old = _Device();
    old.activate();
    await historyService.record(_history(1));
    await readProgressService.updateReadProgress('1', 2);
    await HotDataSyncEngine().sync(bucket);
    bucket.latest = jsonEncode(<dynamic>[
      _entry(CloudConfigTypeEnum.quickSearch, _quickSearchJson(<String, String>{'q': 'old'}), DateTime.now().subtract(const Duration(days: 1))),
    ]);
    bucket.latestTime = DateTime.now().toUtc();
    final String latest = bucket.latest!;
    bucket.writes.clear();

    // The first device of the later version takes it over, then changes q.
    final _Device phone = _Device();
    await phone.sync(bucket);
    expect(await phone.historyGids(), <int>{1});
    expect(await phone.readProgress('1'), 2);
    expect(await phone.quickSearches(), <String, String?>{'q': 'old'});
    await phone.setQuickSearches(<String, String>{'q': 'new'});
    await phone.sync(bucket);

    // A tablet that synced the earlier layout with 8.1.1 upgrades: its
    // quick search was written by that sync, now; it has one of its own,
    // and it read on.
    final _Device tablet = _Device();
    tablet.activate();
    await historyService.record(_history(1));
    await tablet.setQuickSearches(<String, String>{'q': 'old', 'r': 'only on the tablet'});
    await readProgressService.updateReadProgress('1', 5);
    await tablet.sync(bucket);
    expect(await tablet.quickSearches(), <String, String?>{'q': 'new', 'r': 'only on the tablet'});
    expect(await tablet.readProgress('1'), 5);
    await phone.sync(bucket);
    expect(await phone.quickSearches(), <String, String?>{'q': 'new', 'r': 'only on the tablet'});
    expect(await phone.readProgress('1'), 5);

    // 8.1.1 still writes latest.json: not taken any more.
    bucket.latest = jsonEncode(<dynamic>[
      _entry(CloudConfigTypeEnum.quickSearch, _quickSearchJson(<String, String>{'q': 'from 8.1.1'}), DateTime.now().add(const Duration(hours: 1))),
    ]);
    await tablet.sync(bucket);
    await phone.sync(bucket);
    expect((await phone.quickSearches())['q'], 'new');

    expect(bucket.writesOutsideRecords, isEmpty);
    expect(jsonDecode(latest), isNotNull);
  });

  test('history versions of the settings: saved when they change, earlier ones listed too, and one restored goes to the other devices', () async {
    final MemoryBucket bucket = MemoryBucket();
    bucket.versions['20261001000000'] = jsonEncode(<dynamic>[
      _entry(CloudConfigTypeEnum.quickSearch, _quickSearchJson(<String, String>{'v': 'saved by 8.1.1'}), DateTime.utc(2026, 10)),
    ]);
    final _Device phone = _Device(), tablet = _Device();
    phone.settings.enableHistory.value = true;

    await phone.setQuickSearches(<String, String>{'a': 'one'});
    await phone.sync(bucket);
    await phone.sync(bucket);
    expect((await BucketRecordBackend(bucket, device: '').listBackups()), hasLength(1));
    await phone.setQuickSearches(<String, String>{'a': 'two'});
    await phone.sync(bucket);

    phone.activate();
    final SyncService service = phone.service(bucket);
    expect((await service.listHistory()).map((v) => v.version), hasLength(3));
    expect((await service.restoreFromHistory(version: '20261001000000')).success, isTrue);
    expect(await phone.quickSearches(), <String, String?>{'v': 'saved by 8.1.1'});
    await tablet.sync(bucket);
    expect(await tablet.quickSearches(), <String, String?>{'v': 'saved by 8.1.1'});
  });

  test('records compacted into a snapshot reach a new device, deletions included, and packs go once old enough', () async {
    DateTime now = DateTime.utc(2026, 10, 21, 8);
    final MemoryBucket bucket = MemoryBucket(now: () => now);
    final _Device phone = _Device(), tablet = _Device();
    // Read on the tablet before it is deleted on the phone.
    tablet.activate();
    await historyService.record(_history(3));
    phone.activate();
    BucketRecordBackend backend(_Device device) => BucketRecordBackend(bucket, device: 'phone', compactAfter: 3, now: () => now);

    for (int gid = 1; gid <= 5; gid++) {
      await historyService.record(_history(gid));
      await recordSyncEngine.sync(backend(phone));
      now = now.add(const Duration(minutes: 1));
    }
    await historyService.deleteGids(<int>[3]);
    await recordSyncEngine.sync(backend(phone));
    final int packs = (await bucket.listRawObjects(BucketRecordBackend.packsPrefix)).length;
    expect(packs, greaterThan(3));

    await backend(phone).compact();
    expect((await bucket.listRawObjects(BucketRecordBackend.snapshotsPrefix)), hasLength(1));
    expect((await bucket.listRawObjects(BucketRecordBackend.packsPrefix)), hasLength(packs), reason: 'packs are kept a week');

    now = now.add(const Duration(days: 8));
    await historyService.record(_history(6));
    await recordSyncEngine.sync(backend(phone));
    await backend(phone).compact();
    expect((await bucket.listRawObjects(BucketRecordBackend.packsPrefix)), hasLength(lessThan(packs)));
    expect((await bucket.listRawObjects(BucketRecordBackend.snapshotsPrefix)), hasLength(2));

    tablet.activate();
    await recordSyncEngine.sync(BucketRecordBackend(bucket, device: 'tablet', now: () => now));
    expect(await tablet.historyGids(), <int>{1, 2, 4, 5, 6}, reason: 'the deletion of 3 is in the snapshot, and later than the tablet\'s');
  });
}
