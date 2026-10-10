import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/hot_data_sync_engine.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';

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

/// The sync bucket in memory. Downloads of the keys in [failing] fail, every
/// time; [opGets] counts the op packs asked for.
class _MemoryCloud implements CloudProvider {
  final Map<String, List<int>> objects = <String, List<int>>{};
  final Set<String> failing = <String>{};
  int opGets = 0;

  List<String> get opKeys => (objects.keys.where((String k) => k.startsWith('ops/')).toList()..sort());

  @override
  String get name => 'memory';

  @override
  Future<void> putRawObject(String key, List<int> bytes) async => objects[key] = bytes;

  @override
  Future<List<int>?> getRawObject(String key) async {
    if (key.startsWith('ops/')) {
      opGets++;
    }
    if (failing.contains(key)) {
      throw Exception('connection reset');
    }
    return objects[key];
  }

  @override
  Future<List<RemoteObjectInfo>> listRawObjects(String prefix) async => <RemoteObjectInfo>[
        for (final MapEntry<String, List<int>> e in objects.entries)
          if (e.key.startsWith(prefix)) RemoteObjectInfo(key: e.key, size: e.value.length),
      ];

  @override
  Future<void> deleteRawObject(String key) async => objects.remove(key);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

/// One device: its database and the services that live on it.
class _Device {
  final AppDb db = AppDb.forTesting(NativeDatabase.memory());
  final PendingSyncTracker tracker = PendingSyncTracker();
  final ReadProgressService progress = ReadProgressService();
  final HistoryService history = HistoryService();
  final LocalConfigService config = LocalConfigService();

  void activate() {
    appDb = db;
    pendingSyncTracker = tracker;
    readProgressService = progress;
    historyService = history;
    localConfigService = config;
  }

  Future<HotSyncResult> sync(_MemoryCloud cloud) {
    activate();
    return HotDataSyncEngine().sync(cloud);
  }

  Future<Set<int>> historyGids() async {
    activate();
    return (await history.getAllRawHistory()).map((h) => h.gid).toSet();
  }
}

GalleryHistoryModel _entry(int gid) => GalleryHistoryModel(
      // An E-Hentai token is ten characters.
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

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
  });

  test('a device far behind keeps the op packs it got through when a download fails, and goes on from there', () async {
    final _MemoryCloud cloud = _MemoryCloud();
    final _Device phone = _Device();
    final _Device desktop = _Device();

    // The phone reads 45 galleries, syncing after each: 45 op packs.
    for (int gid = 1; gid <= 45; gid++) {
      phone.activate();
      await historyService.record(_entry(gid));
      await phone.sync(cloud);
    }
    final List<String> packs = cloud.opKeys;
    expect(packs, hasLength(45));

    // The desktop starts from nothing; the download of the 31st pack fails.
    cloud.failing.add(packs[30]);
    await expectLater(desktop.sync(cloud), throwsA(isA<Exception>()));

    // Everything up to the end of the chunk before the failed one is applied
    // and recorded: the first 20 packs.
    final Set<int> got = await desktop.historyGids();
    expect(got, <int>{for (int gid = 1; gid <= 20; gid++) gid});
    final String cursors = (await localConfigService.read(configKey: ConfigEnum.oplogAppliedOps))!;
    final String phoneDevice = packs.first.split('/')[1];
    expect(jsonDecode(cursors)[phoneDevice], packs[19].split('/').last.replaceAll('.json.gz', ''));

    // The connection is back: only the packs after the cursor are asked for.
    cloud.failing.clear();
    cloud.opGets = 0;
    final HotSyncResult again = await desktop.sync(cloud);
    expect(again.success, isTrue);
    expect(again.appliedPacks, 25);
    expect(cloud.opGets, 25);
    expect(await desktop.historyGids(), <int>{for (int gid = 1; gid <= 45; gid++) gid});

    await phone.db.close();
    await desktop.db.close();
  });

  test('a download that fails once is tried again and the sync goes through', () async {
    final _MemoryCloud cloud = _MemoryCloud();
    final _Device phone = _Device();
    final _Device desktop = _Device();
    for (int gid = 1; gid <= 3; gid++) {
      phone.activate();
      await historyService.record(_entry(gid));
      await phone.sync(cloud);
    }
    final String flaky = cloud.opKeys[1];
    int attempts = 0;
    final _MemoryCloud onceFlaky = _OnceFlakyCloud(cloud, flaky, () => attempts++);
    final HotSyncResult result = await desktop.sync(onceFlaky);
    expect(result.success, isTrue);
    expect(attempts, 2, reason: 'the first attempt failed, the second got the pack');
    expect(await desktop.historyGids(), <int>{1, 2, 3});
    await phone.db.close();
    await desktop.db.close();
  });
}

/// [inner]'s objects; the first download of [flaky] fails.
class _OnceFlakyCloud extends _MemoryCloud {
  _OnceFlakyCloud(_MemoryCloud inner, this.flaky, this.onAttempt) {
    objects.addAll(inner.objects);
  }

  final String flaky;
  final void Function() onAttempt;
  bool _failed = false;

  @override
  Future<List<int>?> getRawObject(String key) async {
    if (key == flaky) {
      onAttempt();
      if (!_failed) {
        _failed = true;
        throw Exception('connection reset');
      }
    }
    return super.getRawObject(key);
  }
}
