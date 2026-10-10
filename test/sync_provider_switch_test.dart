import 'dart:collection';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/record_sync/record_backend.dart';
import 'package:jhentai/src/service/sync_service.dart';
import 'package:jhentai/src/setting/sync_setting.dart';

/// A device that leaves the bucket for the sync server and comes back must
/// still sync with the devices that never left: what it changed meanwhile
/// reaches the bucket, and what they changed meanwhile reaches the server.

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

/// A bucket in memory: latest.json plus the op packs, snapshots and manifest.
class _MemoryBucket implements CloudProvider {
  String? latest;
  DateTime? latestTime;
  final Map<String, List<int>> objects = {};

  @override
  String get name => 'memory';

  @override
  Future<String?> download() async => latest;

  @override
  Future<CloudFile> upload(String data, {bool saveHistory = false}) async {
    latest = data;
    latestTime = DateTime.now().toUtc();
    return CloudFile(version: 'latest', modifiedTime: latestTime!, size: data.length);
  }

  @override
  Future<CloudFile?> getFileMetadata() async =>
      latest == null ? null : CloudFile(version: 'latest', modifiedTime: latestTime!, size: latest!.length);

  @override
  Future<void> putRawObject(String key, List<int> bytes) async => objects[key] = bytes;

  @override
  Future<List<int>?> getRawObject(String key) async => objects[key];

  @override
  Future<List<RemoteObjectInfo>> listRawObjects(String prefix) async => [
        for (MapEntry<String, List<int>> e in objects.entries)
          if (e.key.startsWith(prefix)) RemoteObjectInfo(key: e.key, size: e.value.length),
      ];

  @override
  Future<void> deleteRawObject(String key) async => objects.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class _Stored {
  final RemoteRecord record;
  final int seq;

  _Stored(this.record, this.seq);
}

/// The sync server in memory, with the rules of sync_server/src/index.ts.
class _MemoryServer implements RecordBackend {
  final Map<String, _Stored> stored = {};
  int seq = 0;

  @override
  Future<RecordServerInfo> info() async => const RecordServerInfo(protocol: 1, database: 'db-1');

  @override
  Future<void> push(List<RemoteRecord> records) async {
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

class _Device {
  _Device(this.provider);

  /// 's3' or 'server'.
  String provider;

  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final LocalConfigService config = LocalConfigService();
  final HistoryService history = HistoryService();
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final JmFavoriteService jm = JmFavoriteService();
  final SyncSetting settings = SyncSetting()
    ..enableSync.value = true
    ..autoSync.value = true
    ..enableHistory.value = false;

  void activate() {
    appDb = db;
    localConfigService = config;
    historyService = history;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    jmFavoriteService = jm;
    syncSetting = settings;
    settings.currentProvider.value = provider;
  }

  Future<void> sync(_MemoryBucket bucket, _MemoryServer server) async {
    activate();
    SyncResult result = await SyncService(providerFactory: (_) => bucket, recordBackendFactory: () => server)
        .sync(types: CloudConfigTypeEnum.values);
    expect(result.success, isTrue, reason: result.message);
  }

  Future<Set<int>> historyGids() async {
    activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }

  Set<int> favoriteIds() {
    activate();
    return jm.getDisplayFavorites().map((g) => g.gid - GalleryUrl.jmGidOffset).toSet();
  }

  Future<int> readProgress(String key) async {
    activate();
    return progress.getReadProgressByKey(key);
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

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
  });

  test('a device back from the sync server syncs with the bucket both ways, and back on the server again', () async {
    final _MemoryBucket bucket = _MemoryBucket();
    final _MemoryServer server = _MemoryServer();
    final _Device phone = _Device('s3');
    final _Device mac = _Device('s3');

    // Both on the bucket, sharing what they have.
    phone.activate();
    await historyService.record(_entry(1));
    await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0);
    await phone.sync(bucket, server);
    await mac.sync(bucket, server);
    expect(await mac.historyGids(), {1});
    expect(mac.favoriteIds(), {101});

    // The Mac moves to the server and goes on reading there.
    mac.provider = 'server';
    await mac.sync(bucket, server);
    mac.activate();
    await historyService.record(_entry(2));
    await readProgressService.updateReadProgress('2', 7);
    await jmFavoriteService.addFavorite(_jmGallery(102), favoriteCategoryIndex: 1);
    await jmFavoriteService.removeFavorite(_jmGallery(101).gid);
    await mac.sync(bucket, server);
    expect(server.record('history', '2'), isNotNull);
    expect(server.record('jmFavorite', '${_jmGallery(101).gid}')!.deleted, isTrue);

    // Meanwhile the phone, still on the bucket, reads too.
    phone.activate();
    await historyService.record(_entry(3));
    await jmFavoriteService.addFavorite(_jmGallery(103), favoriteCategoryIndex: 0);
    await phone.sync(bucket, server);

    // Back on the bucket: what the Mac did on the server goes up, what the
    // phone did comes down.
    mac.provider = 's3';
    await mac.sync(bucket, server);
    await phone.sync(bucket, server);
    expect(await phone.historyGids(), {1, 2, 3});
    expect(await phone.readProgress('2'), 7);
    // A bucket keeps the union of favorites: the deletion made on the server
    // does not travel through it, and 101 is back on the Mac, as before.
    expect(phone.favoriteIds(), {101, 102, 103});
    expect(await mac.historyGids(), {1, 2, 3});
    expect(mac.favoriteIds(), {101, 102, 103});

    // Changes made on the bucket reach the server once the Mac is back there.
    phone.activate();
    await historyService.record(_entry(4));
    await jmFavoriteService.addFavorite(_jmGallery(104), favoriteCategoryIndex: 0);
    await phone.sync(bucket, server);
    await mac.sync(bucket, server);
    mac.activate();
    await historyService.record(_entry(5));
    await mac.sync(bucket, server);

    mac.provider = 'server';
    await mac.sync(bucket, server);
    for (String gid in ['3', '4', '5']) {
      expect(server.record('history', gid), isNotNull, reason: 'history $gid');
    }
    expect(server.record('jmFavorite', '${_jmGallery(104).gid}'), isNotNull);
    expect(server.record('jmFavorite', '${_jmGallery(103).gid}'), isNotNull);

    // The favorite the bucket brought back predates its deletion on the
    // server: the deletion stands, there and on the Mac.
    expect(server.record('jmFavorite', '${_jmGallery(101).gid}')!.deleted, isTrue);
    expect(mac.favoriteIds(), {102, 103, 104});
  });
}
