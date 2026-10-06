// Live requests to a third-party server whose response times vary widely.
@Timeout(Duration(minutes: 4))
library;

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/network/eh_request.dart';
import 'package:jhentai/src/network/jm/jm_api.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/network/jm/jm_source.dart';
import 'package:jhentai/src/pages/details/details_page.dart';
import 'package:jhentai/src/pages/details/details_page_logic.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/archive_download_service.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/jm_reading_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/loading_state_indicator.dart';

import 'support/e2e_app.dart';

/// Opening a multi-chapter JM album goes on to the chapter being read,
/// against the live JM API. Enabled by test/e2e/jm_e2e.json.
void main() {
  final File config = File('test/e2e/jm_e2e.json');
  final Map<dynamic, dynamic> settings = config.existsSync()
      ? jsonDecode(config.readAsStringSync()) as Map
      : const <String, dynamic>{};
  if (settings['enabled'] != true) {
    test('JM chapter progress e2e', () {}, skip: 'test/e2e/jm_e2e.json is absent');
    return;
  }

  late JmAlbum album;

  setUpAll(() async {
    // flutter_test answers every HTTP request with 400 unless told not to.
    HttpOverrides.global = null;
    log = SilentLogService();
    List<String> domains = <String>[];
    final JmApi api = JmApi(
      dio: Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 60))),
      apiDomains: () => domains,
      onApiDomainsDiscovered: (List<String> latest) => domains = latest,
    );
    ehRequest.jmSource = JmSource(api: api, imageDomain: () => JmApi.imageDomains.first);
    styleSetting.actualLayout = LayoutMode.mobileV2;

    // A serialised album with a few chapters; the most viewed often are.
    final JmSearchResult result = await api.search('原神', order: 'mv');
    for (final JmAlbumSummary summary in result.albums.take(40)) {
      final JmAlbum candidate = await api.album(summary.id);
      if (candidate.chapters.length >= 4) {
        album = candidate;
        return;
      }
    }
    fail('no album with four chapters found');
  });

  setUp(() {
    appDb = AppDb.forTesting(NativeDatabase.memory());
    Get.testMode = true;
    // Registered by the app at start; the details page listens to them.
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    Get.put<ArchiveDownloadService>(archiveDownloadService, permanent: true);
  });

  tearDown(() async {
    Get.reset();
    await appDb.close();
  });

  Future<DetailsPageLogic> openDetails(WidgetTester tester, DetailsPageArgument argument) async {
    tester.view.physicalSize = const Size(1600, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    // Thumbnails are cached in the temporary directory.
    final Directory cache = Directory.systemTemp.createTempSync('jm_chapter_progress_e2e');
    addTearDown(() => cache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => cache.path,
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        GetMaterialApp(
          translations: LocaleText(),
          locale: const Locale('zh', 'CN'),
          home: const Scaffold(),
          getPages: [GetPage(name: Routes.details, page: DetailsPage.new)],
        ),
      );
      Get.toNamed(Routes.details, arguments: argument);
      await tester.pump();
    });
    await tester.runAsync(() => tester.pump(const Duration(milliseconds: 500)));
    final DetailsPageLogic logic = DetailsPageLogic.current!;

    // Real requests run outside the fake clock.
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 120));
    while (logic.state.loadingState != LoadingState.success && DateTime.now().isBefore(deadline)) {
      expect(logic.state.loadingState, isNot(LoadingState.error));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump();
    }
    expect(logic.state.loadingState, LoadingState.success, reason: 'timed out');
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    return logic;
  }

  testWidgets('an album opens on the chapter being read, with its page', (WidgetTester tester) async {
    final int total = album.chapters.length;
    final JmChapterRef reading = album.chapters[2];
    await tester.runAsync(() async {
      // Read on another device: chapter 1 marked read, chapter 3 at page 15.
      await jmReadingService.markRead(<int>[album.chapters[0].id]);
      await jmReadingService.remember(albumId: album.id, pageCounts: <int, int>{reading.id: 30}, openedChapterId: reading.id);
      await readProgressService.updateReadProgress(JmReadingService.chapterKey(reading.id), 14);
    });

    final DetailsPageLogic logic = await openDetails(tester, DetailsPageArgument(galleryUrl: GalleryUrl.jm(album.id)));
    expect(logic.state.galleryUrl.jmChapterId, reading.id);
    expect(find.text('章节 3/$total'), findsOneWidget);
    expect(find.text('P15'), findsWidgets, reason: 'read button and chapter row');

    // The chapter list shows each chapter's state.
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('jmChapterRow')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    // Loading thumbnails keep animating, so the page never settles.
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 200));
    }
    Finder row(JmChapterRef chapter) => find.byKey(ValueKey<String>('jmChapter:${chapter.id}'));
    expect(find.descendant(of: row(album.chapters[0]), matching: find.byIcon(Icons.check)), findsOneWidget);
    expect(find.descendant(of: row(reading), matching: find.textContaining('P15')), findsOneWidget);
    expect(find.descendant(of: row(album.chapters[1]), matching: find.byIcon(Icons.check)), findsNothing);
    expect(find.text('章节 ($total) · 已读 1'), findsOneWidget);
  });

  testWidgets('with only marks, an album opens on the first chapter not read', (WidgetTester tester) async {
    await tester.runAsync(() => jmReadingService.markRead(album.chapters.take(3).map((JmChapterRef c) => c.id).toList()));

    final DetailsPageLogic logic = await openDetails(tester, DetailsPageArgument(galleryUrl: GalleryUrl.jm(album.id)));
    expect(logic.state.galleryUrl.jmChapterId, album.chapters[3].id);
    expect(find.text('章节 4/${album.chapters.length}'), findsOneWidget);
  });

  testWidgets('a chapter picked from the list opens as is', (WidgetTester tester) async {
    await tester.runAsync(() => jmReadingService.markRead(<int>[album.chapters[0].id]));

    final DetailsPageLogic logic = await openDetails(
      tester,
      DetailsPageArgument(galleryUrl: GalleryUrl.jm(album.id), jmExactChapter: true),
    );
    expect(logic.state.galleryUrl.jmChapterId, album.id);
    expect(find.text('章节 1/${album.chapters.length}'), findsOneWidget);
  });
}
