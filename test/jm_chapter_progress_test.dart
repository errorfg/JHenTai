import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/dao/gallery_history_dao.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_history_model.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/pages/history/history_page_logic.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/eh_gallery_list_card_.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/service/cloud/cloud_provider.dart';
import 'package:jhentai/src/service/cloud/hot_data_sync_engine.dart';
import 'package:jhentai/src/service/cloud/pending_sync_tracker.dart';
import 'package:jhentai/src/service/history_service.dart';
import 'package:jhentai/src/service/isolate_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/widget/jm_chapter_dialog.dart';

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

/// The sync bucket both devices use, kept in memory.
class _MemoryCloud implements CloudProvider {
  final Map<String, List<int>> objects = <String, List<int>>{};

  @override
  String get name => 'memory';

  @override
  Future<void> putRawObject(String key, List<int> bytes) async => objects[key] = bytes;

  @override
  Future<List<int>?> getRawObject(String key) async => objects[key];

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

  Future<void> sync(_MemoryCloud cloud) async {
    activate();
    final HotSyncResult result = await HotDataSyncEngine().sync(cloud);
    expect(result.success, isTrue);
    readProgressService.clearCacheAndRefresh();
  }
}

/// An album of six chapters; the album id is its first chapter's.
const List<int> _chapters = <int>[100, 101, 102, 103, 104, 105];

Future<void> _read(int chapterId, {required int page, required int pageCount}) async {
  await jmReadingService.remember(albumId: 100, pageCounts: <int, int>{chapterId: pageCount}, openedChapterId: chapterId);
  await readProgressService.updateReadProgress(JmReadingService.chapterKey(chapterId), page);
}

Future<Map<int, String>> _states() async {
  final Map<int, JmChapterProgress> progress = await jmReadingService.progressOf(_chapters);
  return <int, String>{
    for (final int id in _chapters)
      id: progress[id]!.finished
          ? 'finished'
          : progress[id]!.inProgress
              ? jmChapterPageText(progress[id]!)
              : 'unread',
  };
}

Future<String?> _albumPosition() async => (await jmReadingService.albumProgress(100))?.positionText;

GalleryHistoryModel _history(GalleryUrl url, String title) => GalleryHistoryModel(
      galleryUrl: url,
      title: title,
      category: 'Manga',
      coverUrl: 'https://cdn.example.test/cover.jpg',
      pageCount: 20,
      rating: 0,
      language: '',
      uploader: '',
      publishTime: '',
      isExpunged: false,
      tags: const <String>[],
    );

Future<int> _resume() async =>
    JmReadingService.resumeChapter(_chapters, await jmReadingService.progressOf(_chapters));

void main() {
  setUp(() {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    log = _SilentLogService();
    isolateService = _InlineIsolateService();
    jmReadingService = JmReadingService();
  });

  test('chapter progress, marks and the chapter to continue travel between devices', () async {
    final _MemoryCloud cloud = _MemoryCloud();
    final _Device phone = _Device();
    final _Device desktop = _Device();

    phone.activate();
    // Opening the album keeps its chapters in order.
    await jmReadingService.remember(albumId: 100, chapterIds: _chapters);
    expect(await jmReadingService.albumProgress(100), isNull, reason: 'nothing read yet');
    // Chapter 101 read to the end, 102 to page 15 of 30.
    await _read(101, page: 19, pageCount: 20);
    await _read(102, page: 14, pageCount: 30);
    // The album stands where its highest-numbered chapter with a record is.
    expect(await _albumPosition(), '3/6 · P15/30');
    expect(await _states(), <int, String>{
      100: 'unread',
      101: 'finished',
      102: 'P15/30',
      103: 'unread',
      104: 'unread',
      105: 'unread',
    });
    expect(await _resume(), 102);

    // Everything before chapter 104 has been read elsewhere.
    await jmReadingService.markRead(_chapters.sublist(0, 4));
    expect((await _states()).values.take(4), everyElement('finished'));
    expect(await _resume(), 104);
    expect(await _albumPosition(), '4/6', reason: 'a marked chapter is a record');
    await phone.sync(cloud);

    // The desktop starts empty and gets the same picture.
    await desktop.sync(cloud);
    expect(await _states(), <int, String>{
      100: 'finished',
      101: 'finished',
      102: 'finished',
      103: 'finished',
      104: 'unread',
      105: 'unread',
    });
    expect(await _resume(), 104);
    expect(await _albumPosition(), '4/6');
    expect((await jmReadingService.albumProgress(100))!.fraction, closeTo(4 / 6, 1e-9));
    expect(await jmReadingService.lastOpenedChapter(100), 102);
    // A marked chapter re-read from the reader starts at its first page.
    expect(await readProgressService.getReadProgress(100 + 9000000000), 0);

    // Reading chapter 104 there shows up on the phone.
    await _read(104, page: 5, pageCount: 25);
    await desktop.sync(cloud);
    await phone.sync(cloud);
    expect((await _states())[104], 'P6/25');
    expect(await _resume(), 104);
    expect(await _albumPosition(), '5/6 · P6/25');
    expect(await jmReadingService.lastOpenedChapter(100), 104);

    // Marking is not reading: tidying up earlier chapters keeps the place.
    await jmReadingService.markUnread(<int>[103]);
    expect((await _states())[103], 'unread');
    expect(await _resume(), 104);
    await phone.sync(cloud);
    await desktop.sync(cloud);
    expect((await _states())[103], 'unread');
    expect(await _resume(), 104);

    await phone.db.close();
    await desktop.db.close();
  });

  test('the history shows a multi-chapter album as one entry', () async {
    final _Device device = _Device()..activate();
    // Entries made per chapter by earlier versions, and an unrelated gallery.
    await historyService.record(_history(GalleryUrl.jm(101), 'Album - Chapter 2'));
    await historyService.record(_history(GalleryUrl.jm(103), 'Album - Chapter 4'));
    await historyService.record(_history(GalleryUrl.tryParse('https://e-hentai.org/g/123456/abcdef0123/')!, 'Other'));
    Future<List<String>> shown() async => (await HistoryPageLogic.visibleHistory(0, await historyService.getPageCount()))
        .rows
        .map((GalleryHistoryModel row) => row.title)
        .toList();
    expect(await shown(), <String>['Other', 'Album - Chapter 4', 'Album - Chapter 2'], reason: 'the album is not known yet');

    // Opening the album: its chapters become known and it gets its entry.
    await jmReadingService.remember(albumId: 100, chapterIds: _chapters);
    await historyService.record(_history(GalleryUrl.jm(100), 'Album'));
    expect(await shown(), <String>['Album', 'Other']);
    expect(await jmReadingService.chapterGidsOfKnownAlbums(), <int>{
      for (final int id in _chapters.skip(1)) GalleryUrl.jm(id).gid,
    });
    // The old entries are kept, only not shown.
    expect(await GalleryHistoryDao.selectTotalCount(), 4);

    await device.db.close();
  });

  testWidgets('a list card of a multi-chapter album shows where the album stands', (WidgetTester tester) async {
    final _Device device = (await tester.runAsync(() async => _Device()..activate()))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    addTearDown(Get.reset);
    final Directory cache = Directory.systemTemp.createTempSync('jm_card_test');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => cache.path,
    );
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await jmReadingService.remember(albumId: 100, chapterIds: _chapters);
      await jmReadingService.markRead(<int>[100, 101]);
      await _read(102, page: 14, pageCount: 30);
    });

    final Gallery album = Gallery(
      galleryUrl: GalleryUrl.jm(100),
      title: 'Album',
      category: 'Manga',
      cover: GalleryImage(url: 'https://cdn.example.test/cover.jpg'),
      pageCount: 4520,
      rating: 0,
      hasRated: false,
      favoriteTagIndex: null,
      favoriteTagName: null,
      language: null,
      uploader: null,
      publishTime: '',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EHGalleryListCard(
              gallery: album,
              downloaded: false,
              listMode: ListMode.listWithoutTags,
              handleTapCard: (_) {},
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();

    // Chapter 3 of 6, at page 15 of 30; the ring stands at chapter 3.
    expect(find.text('3/6 · P15/30'), findsOneWidget);
    final CircularProgressIndicator ring = tester.widget(find.byType(CircularProgressIndicator));
    expect(ring.value, closeTo(0.5, 1e-9));
    expect(find.text('4520P'), findsOneWidget);

    await tester.runAsync(device.db.close);
  });

  test('the chapter to continue with', () {
    JmChapterProgress reading(int page, String at, {int? pages}) =>
        JmChapterProgress(pageIndex: page, pageCount: pages, readAt: at);
    const JmChapterProgress marked = JmChapterProgress(markedRead: true);
    const List<int> ids = <int>[1, 2, 3, 4];

    expect(JmReadingService.resumeChapter(ids, const <int, JmChapterProgress>{}), 1);
    // The chapter read last, even if an earlier one was read further.
    expect(
      JmReadingService.resumeChapter(ids, <int, JmChapterProgress>{
        1: reading(3, '2026-10-01T00:00:00.000000Z'),
        3: reading(1, '2026-10-02T00:00:00.000000Z'),
      }),
      3,
    );
    // Finished: the next one not finished.
    expect(
      JmReadingService.resumeChapter(ids, <int, JmChapterProgress>{
        1: reading(9, '2026-10-02T00:00:00.000000Z', pages: 10),
        2: marked,
      }),
      3,
    );
    // Everything finished: stay on the last chapter read.
    expect(
      JmReadingService.resumeChapter(ids, <int, JmChapterProgress>{
        1: marked,
        2: reading(9, '2026-10-02T00:00:00.000000Z', pages: 10),
        3: marked,
        4: marked,
      }),
      2,
    );
    // Only marks: the first unfinished chapter; all marked: the last.
    expect(JmReadingService.resumeChapter(ids, <int, JmChapterProgress>{1: marked, 2: marked}), 3);
    expect(JmReadingService.resumeChapter(ids, <int, JmChapterProgress>{1: marked, 2: marked, 3: marked, 4: marked}), 4);
  });

  testWidgets('the chapter list shows each chapter\'s progress and marks earlier chapters read', (WidgetTester tester) async {
    // Opened on real time: the database schedules its opening on the zone
    // it is created in.
    final _Device device = (await tester.runAsync(() async => _Device()..activate()))!;
    final List<JmChapterRef> chapters = <JmChapterRef>[
      for (int i = 0; i < 4; i++) JmChapterRef(id: 200 + i, name: 'Chapter ${i + 1}', sort: i + 1),
    ];

    await tester.runAsync(() async {
      await jmReadingService.markRead(<int>[200]);
      await jmReadingService.remember(albumId: 200, pageCounts: <int, int>{201: 30});
      await readProgressService.updateReadProgress(JmReadingService.chapterKey(201), 14);
    });

    int marked = 0;
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: JmChapterDialog(
              chapters: chapters,
              currentChapterId: 201,
              onTap: (_) {},
              onMarked: () => marked++,
            ),
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();

    Finder row(int id) => find.byKey(ValueKey<String>('jmChapter:$id'));
    expect(find.descendant(of: row(200), matching: find.byIcon(Icons.check)), findsOneWidget);
    expect(find.descendant(of: row(201), matching: find.text('P15/30')), findsOneWidget);
    expect(find.descendant(of: row(201), matching: find.byType(LinearProgressIndicator)), findsOneWidget);
    expect(find.descendant(of: row(202), matching: find.byIcon(Icons.check)), findsNothing);
    expect(find.textContaining('chaptersReadCount'), findsOneWidget);

    // From chapter 4: everything before it is read.
    await tester.tap(find.byKey(const ValueKey<String>('jmChapterMenu:203')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('markPreviousChaptersRead'));
    // The marks are written and the list reloads from the database.
    for (int i = 0; i < 20 && marked == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();

    for (final int id in <int>[200, 201, 202]) {
      expect(find.descendant(of: row(id), matching: find.byIcon(Icons.check)), findsOneWidget, reason: 'chapter $id');
    }
    expect(find.descendant(of: row(203), matching: find.byIcon(Icons.check)), findsNothing);
    expect(marked, 1);
    await tester.runAsync(() async {
      final Map<int, JmChapterProgress> progress = await jmReadingService.progressOf(<int>[200, 201, 202, 203]);
      expect(progress.values.map((JmChapterProgress p) => p.finished), <bool>[true, true, true, false]);
    });

    await tester.runAsync(device.db.close);
  });
}
