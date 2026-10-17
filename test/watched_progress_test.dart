import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_page.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/pages/read/brightness_lock.dart';
import 'package:jhentai/src/pages/watched/progress/watched_progress_page.dart';
import 'package:jhentai/src/pages/watched/watched_card.dart';
import 'package:jhentai/src/pages/watched/watched_page_logic.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/watched_progress_service.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:visibility_detector/visibility_detector.dart';

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

/// The watched list's logic without its page: what the timeline opens is
/// written down instead of loaded.
class _ListAtHand extends WatchedPageLogic {
  final List<int> openedAt = <int>[];

  @override
  // ignore: must_call_super
  Future<void> onInit() async {}

  @override
  Future<void> jumpToGallery(int gid) async => openedAt.add(gid);
}

/// The watched list's logic with pages made up here: each page asked for
/// is written down, and can be held back.
class _PagedList extends WatchedPageLogic {
  final List<String?> asked = <String?>[];
  Completer<void>? hold;

  @override
  // ignore: must_call_super
  Future<void> onInit() async {}

  @override
  Future<GalleryPageInfo> getGalleryPage({String? prevGid, String? nextGid, DateTime? seek}) async {
    asked.add(nextGid);
    await hold?.future;
    final int first = nextGid == null ? 3500000 : int.parse(nextGid) - 1;
    return GalleryPageInfo(gallerys: _list(5, newestGid: first), nextGid: '${first - 4}', prevGid: nextGid == null ? null : '$first');
  }

  @override
  Future<List<Gallery>> postHandleNewGallerys(List<Gallery> gallerys, {bool cleanDuplicate = true}) async => gallerys;
}

/// The watched list: [count] galleries, newest (highest gid) first, about
/// twenty a day back from 2026-10-18.
List<Gallery> _list(int count, {int newestGid = 3500000}) => <Gallery>[
      for (int i = 0; i < count; i++) _gallery(newestGid - i, day: 18 - i ~/ 20),
    ];

Gallery _gallery(int gid, {required int day}) => Gallery(
      galleryUrl: GalleryUrl(isEH: true, gid: gid, token: 'abcdef1234'),
      title: 'Gallery $gid',
      category: 'Manga',
      cover: GalleryImage(url: 'https://ehgt.org/t/$gid.jpg', width: 250, height: 350),
      pageCount: 20,
      rating: 4,
      hasRated: false,
      language: 'japanese',
      uploader: 'someone',
      publishTime: '2026-${day > 0 ? '10' : '09'}-${(day > 0 ? day : 30 + day).toString().padLeft(2, '0')} 12:00',
      isExpunged: false,
      tags: LinkedHashMap<String, List<GalleryTag>>(),
    );

/// Covers that never load keep spinning: a route change is waited for
/// rather than settled.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
}

List<List<int>> _stretches() =>
    watchedProgressService.ranges.map((WatchedReadRange r) => r.gallerys.map((WatchedGallery g) => g.gid).toList()).toList();

void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    Get.testMode = true;
    watchedProgressService = WatchedProgressService()..flushDelay = const Duration(days: 1);
    Get.put<WatchedProgressService>(watchedProgressService, permanent: true);
  });

  tearDown(() async {
    Get.reset();
    await appDb.close();
  });

  group('what was read', () {
    test('galleries scrolled past in one go are one stretch; a jump starts another', () {
      final List<Gallery> list = _list(10);
      watchedProgressService.markRead(list, 0, 4);
      // Jumped further down: another list, not next to the first stretch.
      watchedProgressService.markRead(list, 7, 9);

      expect(_stretches(), <List<int>>[
        <int>[3500000, 3499999, 3499998, 3499997, 3499996],
        <int>[3499993, 3499992, 3499991],
      ]);
      expect(watchedProgressService.isRead(3499995), isFalse);
      expect(watchedProgressService.readCount, 8);
    });

    test('scrolling across the gap later joins the two stretches into one', () {
      final List<Gallery> list = _list(10);
      watchedProgressService
        ..markRead(list, 0, 4)
        ..markRead(list, 7, 9);
      // Another day, another list opened at the last gallery of the upper
      // stretch: the two cards seen below it close the gap, between a read
      // gallery above and one below.
      watchedProgressService.markRead(list.sublist(4), 1, 2);

      expect(_stretches(), <List<int>>[
        <int>[for (int gid = 3500000; gid > 3499990; gid--) gid],
      ]);
    });

    test('what was read and bookmarked is there after a restart', () async {
      final List<Gallery> list = _list(10);
      watchedProgressService
        ..markRead(list, 0, 4)
        ..markRead(list, 7, 9)
        ..addBookmark(list[8])
        ..addBookmark(list[2])
        ..setLastPosition(list[3]);
      await watchedProgressService.flush();

      final WatchedProgressService restarted = WatchedProgressService();
      await restarted.load();
      watchedProgressService = restarted;
      expect(_stretches(), hasLength(2));
      expect(restarted.ranges.first.newest.title, 'Gallery 3500000');
      expect(restarted.ranges.first.newest.cover.url, 'https://ehgt.org/t/3500000.jpg');
      expect(restarted.ranges.first.newest.day, '2026-10-18');
      // In the order of the list, whatever the order they were added.
      expect(restarted.bookmarks.map((WatchedGallery b) => b.gid), <int>[3499998, 3499992]);
      expect(restarted.lastPosition?.gid, 3499997);

      restarted.removeBookmark(3499998);
      await restarted.flush();
      await (watchedProgressService = WatchedProgressService()).load();
      expect(watchedProgressService.bookmarks.map((WatchedGallery b) => b.gid), <int>[3499992]);
    });
  });

  test('a card reported far from the stretch seen so far: all between went past the screen too', () {
    final _ListAtHand logic = _ListAtHand();
    final List<Gallery> list = _list(30);
    logic.state.gallerys = list;
    List<int> read() => <int>[for (int i = 0; i < list.length; i++) if (watchedProgressService.isRead(list[i].gid)) i];

    logic
      ..onCardVisibilityChanged(list[10], 1)
      ..onCardVisibilityChanged(list[11], 0.6)
      // A fling down, reported only where it stopped.
      ..onCardVisibilityChanged(list[24], 1);
    expect(read(), <int>[for (int i = 10; i <= 24; i++) i]);
    // Up past where it began.
    logic.onCardVisibilityChanged(list[3], 0.8);
    expect(read(), <int>[for (int i = 3; i <= 24; i++) i]);
    // Hardly on screen: not seen.
    logic.onCardVisibilityChanged(list[27], 0.3);
    expect(read().last, 24);
    expect(_stretches(), hasLength(1));
  });

  test('opened at a gallery while its first page loads, the list goes to the gallery once that is done', () async {
    final _PagedList logic = _PagedList()..hold = Completer<void>();
    final Future<void> firstPage = logic.loadMore();
    await logic.showFrom(3400000);
    expect(logic.asked, <String?>[null], reason: 'waits for the first page');

    logic.hold!.complete();
    await firstPage;
    expect(logic.asked, <String?>[null, '3400001']);
    expect(logic.state.gallerys.first.gid, 3400000);

    // Free: at once.
    await logic.showFrom(3300000);
    expect(logic.asked.last, '3300001');
    expect(logic.state.gallerys.first.gid, 3300000);
  });

  group('the watched list', () {
    late _ListAtHand logic;

    Future<void> showList(WidgetTester tester, List<Gallery> list) async {
      logic.state.gallerys = list;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView.builder(
              controller: logic.state.scrollController,
              itemCount: list.length,
              itemBuilder: (BuildContext context, int index) => logic.cardWrapper!(
                list[index],
                SizedBox(height: 120, child: Text('card ${list[index].gid}')),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    double opacityOf(WidgetTester tester, int gid) =>
        tester.widget<Opacity>(find.ancestor(of: find.text('card $gid'), matching: find.byType(Opacity)).first).opacity;

    setUp(() {
      VisibilityDetectorController.instance.updateInterval = Duration.zero;
      logic = _ListAtHand()..positionDelay = Duration.zero;
      logic.onStart();
    });

    testWidgets('cards seen are read, and so is all a fling goes past; the top card is where the list was left', (WidgetTester tester) async {
      final List<Gallery> list = _list(60);
      await showList(tester, list);

      // 600 px of 120 px cards: five on screen.
      expect(<int>[for (final Gallery g in list) if (watchedProgressService.isRead(g.gid)) g.gid], <int>[for (int i = 0; i < 5; i++) list[i].gid]);
      expect(watchedProgressService.lastPosition, isNull, reason: 'not scrolled by hand yet');
      expect(opacityOf(tester, list[0].gid), 1, reason: 'not faded while it is looked at');

      // A fling far down.
      await tester.fling(find.byType(ListView), const Offset(0, -3000), 4000);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 10));

      final int top = list.indexWhere((Gallery g) => find.text('card ${g.gid}').evaluate().isNotEmpty);
      expect(top, greaterThan(20));
      final List<int> read = <int>[for (int i = 0; i < list.length; i++) if (watchedProgressService.isRead(list[i].gid)) i];
      expect(read.first, 0);
      expect(read, <int>[for (int i = 0; i <= read.last; i++) i], reason: 'nothing a fling went past is left out');
      expect(read.last, greaterThanOrEqualTo(top + 3));
      expect(_stretches(), hasLength(1));
      // The top card at least half on screen.
      final int topSeen = <int>[top, top + 1].firstWhere((int i) {
        final Rect box = tester.getRect(find.text('card ${list[i].gid}'));
        return box.top >= -60;
      });
      expect(watchedProgressService.lastPosition?.gid, list[topSeen].gid);

      // Back at the top: the cards read show faded now.
      await tester.fling(find.byType(ListView), const Offset(0, 6000), 6000);
      await tester.pumpAndSettle();
      expect(opacityOf(tester, list[0].gid), WatchedCard.readOpacity);
      await tester.runAsync(watchedProgressService.flush);
    });

    testWidgets('a bookmarked card carries a ribbon', (WidgetTester tester) async {
      final List<Gallery> list = _list(10);
      await showList(tester, list);
      expect(find.byIcon(Icons.bookmark), findsNothing);
      logic.toggleBookmark(list[1]);
      await tester.pump();
      expect(find.byIcon(Icons.bookmark), findsOneWidget);
      logic.toggleBookmark(list[1]);
      await tester.pump();
      expect(find.byIcon(Icons.bookmark), findsNothing);
      await tester.runAsync(watchedProgressService.flush);
    });
  });

  testWidgets('the timeline shows each stretch with its ends and the unread part below, and opens the list where tapped', (WidgetTester tester) async {
    final _ListAtHand list = Get.put<WatchedPageLogic>(_ListAtHand(), permanent: true) as _ListAtHand;
    final List<Gallery> gallerys = _list(80);
    watchedProgressService
      ..markRead(gallerys, 0, 29)
      ..markRead(gallerys, 50, 69)
      ..addBookmark(gallerys[40])
      ..setLastPosition(gallerys[29]);

    await tester.pumpWidget(GetMaterialApp(
      home: const Scaffold(body: Text('watched list')),
      getPages: [GetPage(name: '/progress', page: () => const WatchedProgressPage())],
    ));
    Get.toNamed('/progress');
    await settle(tester);

    expect(find.text('50'), findsOneWidget, reason: 'galleries read');
    expect(find.byKey(Key('watchedRange-${gallerys[0].gid}')), findsOneWidget);
    expect(find.byKey(Key('watchedRange-${gallerys[50].gid}')), findsOneWidget);
    // Each stretch shows both its ends; the bookmark lies in the unread part
    // between them.
    expect(find.byKey(Key('watchedEnd-${gallerys[29].gid}')), findsOneWidget);
    expect(find.descendant(of: find.byKey(Key('watchedGap-${gallerys[29].gid}')), matching: find.byKey(Key('watchedBookmark-${gallerys[40].gid}'))), findsOneWidget);
    expect(find.byKey(const Key('watchedLastPosition')), findsOneWidget);

    // Down from the end of the first stretch.
    await tester.tap(find.byKey(Key('watchedContinueBelow-${gallerys[29].gid}')));
    await settle(tester);
    expect(list.openedAt, <int>[gallerys[29].gid]);
    expect(find.text('watched list'), findsOneWidget, reason: 'back on the list');

    // Removing the bookmark from the timeline.
    Get.toNamed('/progress');
    await settle(tester);
    await tester.scrollUntilVisible(find.byKey(Key('watchedBookmarkRemove-${gallerys[40].gid}')), 200);
    await tester.tap(find.byKey(Key('watchedBookmarkRemove-${gallerys[40].gid}')));
    await tester.pump();
    expect(watchedProgressService.bookmarks, isEmpty);
    expect(find.byKey(Key('watchedBookmark-${gallerys[40].gid}')), findsNothing);
    await tester.runAsync(watchedProgressService.flush);
  });

  test('the brightness lock takes the brightness the screen has, and undoing it gives it back', () async {
    readSetting.enableCustomReadBrightness.value = false;
    readSetting.customBrightness.value = 50;

    expect(await toggleReadBrightnessLock(screenBrightness: () async => 0.374), 'brightnessLocked');
    expect(readSetting.enableCustomReadBrightness.value, isTrue);
    expect(readSetting.customBrightness.value, 37);

    expect(await toggleReadBrightnessLock(screenBrightness: () async => fail('not read when undoing')), 'brightnessUnlocked');
    expect(readSetting.enableCustomReadBrightness.value, isFalse);
    expect(readSetting.customBrightness.value, 37);

    expect(await toggleReadBrightnessLock(screenBrightness: () async => throw const OSError('no screen')), 'internalError');
    expect(readSetting.enableCustomReadBrightness.value, isFalse);
  });
}
