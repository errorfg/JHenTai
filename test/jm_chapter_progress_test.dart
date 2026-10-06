import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/database/database.dart';
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
    // Chapter 101 read to the end, 102 to page 15 of 30.
    await _read(101, page: 19, pageCount: 20);
    await _read(102, page: 14, pageCount: 30);
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
    expect(await jmReadingService.lastOpenedChapter(100), 102);
    // A marked chapter re-read from the reader starts at its first page.
    expect(await readProgressService.getReadProgress(100 + 9000000000), 0);

    // Reading chapter 104 there shows up on the phone.
    await _read(104, page: 5, pageCount: 25);
    await desktop.sync(cloud);
    await phone.sync(cloud);
    expect((await _states())[104], 'P6/25');
    expect(await _resume(), 104);
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
