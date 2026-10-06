import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dio/dio.dart' show CancelToken;
import 'package:drift/native.dart';
import 'package:executor/executor.dart' show AsyncTask;
import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/pages/read/layout/vertical_list/vertical_list_layout_logic.dart';
import 'package:jhentai/src/pages/read/read_page.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/sr/sr_tools.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

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

const int _pages = 5;

/// A chapter of [_pages] pages read from files, as downloaded pages are.
ReadPageInfo _chapter(
  int chapter, {
  required List<String> shown,
  Future<ReadPageInfo?> Function({required bool next})? next,
}) {
  return ReadPageInfo(
    mode: ReadMode.online,
    gid: chapter,
    token: 'test',
    galleryTitle: 'Chapter $chapter',
    galleryUrl: 'https://example.test/chapter/$chapter',
    initialIndex: 0,
    pageCount: _pages,
    readProgressRecordStorageKey: 'chapter-$chapter',
    thumbnails: <GalleryThumbnail?>[
      for (int i = 0; i < _pages; i++) GalleryThumbnail(href: 'test://$chapter/$i', isLarge: true, thumbUrl: ''),
    ],
    images: <GalleryImage?>[
      for (int i = 0; i < _pages; i++)
        GalleryImage(url: 'test://$chapter/$i', path: 'c$chapter-$i.png', downloadStatus: DownloadStatus.downloaded),
    ],
    onShown: () => shown.add('Chapter $chapter'),
    useSuperResolution: false,
    loadSiblingBook: next,
    siblingsAreChapters: true,
  );
}

/// Where the upscaler programs are, from test/e2e/sr_e2e.json; null to skip
/// the tests that run them.
String? _srToolsRoot() {
  final File config = File('test/e2e/sr_e2e.json');
  final String? root = config.existsSync() ? (jsonDecode(config.readAsStringSync()) as Map)['toolsRoot'] as String? : null;
  return root != null && SrEngine.realesrgan.isInstalled(root) ? root : null;
}

void main() {
  late Directory files;

  setUpAll(() {
    log = _SilentLogService();
    files = Directory.systemTemp.createTempSync('read_books_in_a_row');
    // Pages as tall as most of the screen, so a few show at once.
    for (final int chapter in <int>[1, 2]) {
      for (int i = 0; i < _pages; i++) {
        final img.Image page = img.Image(width: 300, height: 400);
        img.fill(page, color: img.ColorRgb8(40 * i, chapter * 100, 200));
        File('${files.path}/c$chapter-$i.png').writeAsBytesSync(img.encodePng(page));
      }
    }
    pathService.appDocDir = files;
  });

  tearDownAll(() => files.deleteSync(recursive: true));

  testWidgets('the next chapter follows the last page, and each keeps its own progress', (WidgetTester tester) async {
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    readSetting.readDirection.value = ReadDirection.top2bottomList;
    readSetting.keepScreenAwakeWhenReading.value = false;
    readSetting.showThumbnails.value = false;
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    // The reader lets the screen sleep again when it closes.
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );

    final List<String> shown = <String>[];
    int loads = 0;
    final ReadPageInfo first = _chapter(
      1,
      shown: shown,
      next: ({required bool next}) async {
        loads++;
        return next ? _chapter(2, shown: shown, next: ({required bool next}) async => null) : null;
      },
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: const Scaffold(),
          getPages: [GetPage(name: '/read', page: () => const ReadPage())],
        ),
      );
      Get.toNamed('/read', arguments: first);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    Future<void> settle() async {
      for (int i = 0; i < 6; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await settle();
    final ReadPageLogic reader = Get.find<ReadPageLogic>();
    expect(shown, <String>['Chapter 1']);
    expect(reader.state.readPageInfo.pageCount, _pages);

    // Down to the last page of chapter 1: chapter 2 is appended below it.
    Get.find<VerticalListLayoutLogic>().state.itemScrollController.jumpTo(index: _pages - 1);
    await settle();
    expect(loads, 1);
    expect(reader.state.segments, hasLength(2));
    expect(reader.state.readPageInfo.pageCount, 2 * _pages);
    expect(reader.currentSegment.info.galleryTitle, 'Chapter 1');
    expect(reader.reachedEnd, isTrue);
    // The next chapter is already there: no button to it.
    expect(reader.showsNextBookButton, isFalse);

    // On into chapter 2, page 2.
    Get.find<VerticalListLayoutLogic>().state.itemScrollController.jumpTo(index: _pages + 1);
    await settle();
    expect(reader.currentSegment.info.galleryTitle, 'Chapter 2');
    expect(reader.pageNumberOf(reader.state.readPageInfo.currentImageIndex), 2);
    expect(shown, <String>['Chapter 1', 'Chapter 2']);
    expect(find.text('Chapter 2'), findsWidgets);

    // Leaving the reader keeps where each chapter was.
    await tester.runAsync(() async {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle();
    final Map<String, ReadProgressRecord> progress = (await tester.runAsync(
      () => readProgressService.getProgressRecords(<String>{'chapter-1', 'chapter-2'}),
    ))!;
    expect(progress['chapter-1']?.value, '${_pages - 1}');
    expect(progress['chapter-2']?.value, '1');

    await tester.runAsync(() async {
      Get.reset();
      await appDb.close();
    });
  });
  testWidgets('with upscaling on, a page is replaced by its upscaled copy; switched off, the original is back', (WidgetTester tester) async {
    final String toolsRoot = _srToolsRoot()!;
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    readSetting.readDirection.value = ReadDirection.top2bottomList;
    readSetting.keepScreenAwakeWhenReading.value = false;
    readSetting.showThumbnails.value = false;
    superResolutionSetting = SuperResolutionSetting()..realtimeEnabled.value = true;
    final Directory cache = Directory.systemTemp.createTempSync('read_sr_cache');
    addTearDown(() => cache.deleteSync(recursive: true));
    realtimeSrService = RealtimeSrService()
      ..toolsRootOverride = toolsRoot
      ..workDirOverride = cache.path;
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: const Scaffold(),
          getPages: [GetPage(name: '/read', page: () => const ReadPage())],
        ),
      );
      Get.toNamed('/read', arguments: _chapter(1, shown: <String>[]));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    for (int i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    final ReadPageLogic reader = Get.find<ReadPageLogic>();
    expect(reader.realtimeSrOn, isTrue);

    // The first page shown: 300 x 400 as stored, then its upscaled copy.
    ui.Image shown() => tester.widget<ExtendedRawImage>(find.byType(ExtendedRawImage).first).image!;
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 60));
    while (reader.upscaledPage(0) == null && DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(reader.upscaledPage(0), isNotNull, reason: 'the first page was not upscaled');
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect((shown().width, shown().height), (600, 800));
    // The five pages of the chapter were fetched ahead and upscaled four to a
    // run; the results are in memory, and no file is left.
    final DateTime allDone = DateTime.now().add(const Duration(seconds: 30));
    while (reader.upscaledPage(4) == null && DateTime.now().isBefore(allDone)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(realtimeSrService.batchSizes, <int>[4, 1]);
    expect(<int>[for (int i = 0; i < 5; i++) if (reader.upscaledPage(i) != null) i], <int>[0, 1, 2, 3, 4]);
    expect(cache.listSync(recursive: true), isEmpty);

    // The scale is changed in the settings while the page is read: the page
    // is upscaled anew and shows at three times its size.
    (int, int)? size() {
      final Iterable<Element> found = find.byType(ExtendedRawImage).evaluate();
      final ui.Image? image = found.isEmpty ? null : (found.first.widget as ExtendedRawImage).image;
      return image == null ? null : (image.width, image.height);
    }

    Future<void> shows((int, int) wanted) async {
      final DateTime until = DateTime.now().add(const Duration(seconds: 60));
      while (size() != wanted && DateTime.now().isBefore(until)) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(size(), wanted);
    }

    Future<void> setScale(int scale) => tester.runAsync(
          () => superResolutionSetting.saveRealtimeConfig(
            model: superResolutionSetting.realtimeModel.value,
            scale: scale,
            denoise: superResolutionSetting.realtimeDenoise.value,
          ),
        );

    int runs = realtimeSrService.runs;
    await setScale(3);
    await shows((900, 1200));
    expect(realtimeSrService.runs, greaterThan(runs));

    // Back to the scale tried before: its pages are in memory, the program
    // is not run for them again.
    await setScale(2);
    runs = realtimeSrService.runs;
    await shows((600, 800));
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(realtimeSrService.runs, runs);
    expect(<int>[for (int i = 0; i < 5; i++) if (reader.upscaledPage(i) != null) i], <int>[0, 1, 2, 3, 4]);

    // Off: the original again, once it is decoded anew.
    await tester.runAsync(reader.toggleRealtimeSr);
    expect(reader.realtimeSrOn, isFalse);
    final DateTime reloaded = DateTime.now().add(const Duration(seconds: 20));
    do {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    } while (find.byType(ExtendedRawImage).evaluate().isEmpty && DateTime.now().isBefore(reloaded));
    expect((shown().width, shown().height), (300, 400));

    await tester.runAsync(() async {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    // The route leaves and the reader is disposed with it.
    for (int i = 0; i < 10; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(Get.isRegistered<ReadPageLogic>(), isFalse);
    await tester.runAsync(() async {
      Get.reset();
      await appDb.close();
    });
  }, skip: _srToolsRoot() == null);

  /// Reads [info] with upscaling on until the pages [upscaled] have their
  /// upscaled copy, and checks that the first page shows as it: the reader's
  /// switch is there, and the pages [left] are left alone.
  Future<void> readUpscaled(
    WidgetTester tester,
    ReadPageInfo info, {
    List<int> upscaled = const <int>[0, 1, 2, 3, 4],
    List<int> left = const <int>[],
  }) async {
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    readSetting.readDirection.value = ReadDirection.top2bottomList;
    readSetting.keepScreenAwakeWhenReading.value = false;
    readSetting.showThumbnails.value = false;
    superResolutionSetting = SuperResolutionSetting()..realtimeEnabled.value = true;
    final Directory cache = Directory.systemTemp.createTempSync('read_sr_cache');
    addTearDown(() => cache.deleteSync(recursive: true));
    realtimeSrService = RealtimeSrService()
      ..toolsRootOverride = _srToolsRoot()!
      ..workDirOverride = cache.path;
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
    // The image cache of pages fetched from a server.
    final Directory imageCache = Directory.systemTemp.createTempSync('read_sr_images');
    addTearDown(() => imageCache.deleteSync(recursive: true));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => imageCache.path,
    );
    Future<void> settle([int rounds = 6]) async {
      for (int i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.runAsync(() async {
      await tester.pumpWidget(
        GetMaterialApp(
          home: const Scaffold(),
          getPages: [GetPage(name: '/read', page: () => const ReadPage())],
        ),
      );
      Get.toNamed('/read', arguments: info);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await settle();
    final ReadPageLogic reader = Get.find<ReadPageLogic>();
    expect(reader.realtimeSrOn, isTrue);
    // In the reader's menu, shown or not.
    expect(find.byKey(const Key('realtimeSrToggle')), findsOneWidget);

    final DateTime deadline = DateTime.now().add(const Duration(seconds: 90));
    while (upscaled.any((int i) => reader.upscaledPage(i) == null) && DateTime.now().isBefore(deadline)) {
      await settle(1);
    }
    expect(<int>[for (int i = 0; i < info.pageCount; i++) if (reader.upscaledPage(i) != null) i], upscaled);
    for (final int index in left) {
      expect(reader.upscaledPage(index), isNull, reason: 'page $index');
    }
    await settle();
    // 300 x 400 as stored, twice that upscaled.
    final ui.Image shown = tester.widget<ExtendedRawImage>(find.byType(ExtendedRawImage).first).image!;
    expect((shown.width, shown.height), (600, 800));
    expect(cache.listSync(recursive: true), isEmpty);

    await tester.runAsync(() async {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle(10);
    expect(Get.isRegistered<ReadPageLogic>(), isFalse);
    await tester.runAsync(() async {
      Get.reset();
      await appDb.close();
    });
  }

  testWidgets('pages read from a Komga server are upscaled, fetched with its login', (WidgetTester tester) async {
    // The test binding answers every request itself otherwise.
    HttpOverrides.global = null;
    final Map<String, int> served = <String, int>{};
    int refused = 0;
    final HttpServer server = (await tester.runAsync(() async {
      final HttpServer server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest request) async {
        // No connection kept: an idle one leaves a timer behind in the test.
        request.response.persistentConnection = false;
        if (request.headers.value('X-API-Key') != 'key-of-the-test') {
          refused++;
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          final int page = int.parse(request.uri.pathSegments.last);
          served[request.uri.path] = (served[request.uri.path] ?? 0) + 1;
          request.response
            ..headers.contentType = ContentType('image', 'png')
            ..add(File('${files.path}/c1-${page - 1}.png').readAsBytesSync());
        }
        await request.response.close();
      });
      return server;
    }))!;
    addTearDown(() => tester.runAsync(() => server.close(force: true)));

    // As the Komga reader launcher makes a book's session.
    await readUpscaled(
      tester,
      ReadPageInfo(
        mode: ReadMode.remote,
        galleryTitle: 'Volume 1',
        initialIndex: 0,
        pageCount: _pages,
        readProgressRecordStorageKey: 'komga:test:book-1',
        images: <GalleryImage?>[
          for (int i = 0; i < _pages; i++)
            GalleryImage(
              url: 'http://127.0.0.1:${server.port}/api/v1/books/book-1/pages/${i + 1}',
              headers: const <String, String>{'X-API-Key': 'key-of-the-test', 'Accept': 'image/*'},
              cacheKey: 'komga-test-book-1-${i + 1}',
              downloadStatus: DownloadStatus.downloaded,
            ),
        ],
        useSuperResolution: false,
      ),
    );

    expect(refused, 0);
    expect(served.keys.toSet(), <String>{for (int i = 1; i <= _pages; i++) '/api/v1/books/book-1/pages/$i'});
  }, skip: _srToolsRoot() == null);

  testWidgets('a downloaded Komga book is upscaled as it is read', (WidgetTester tester) async {
    await readUpscaled(
      tester,
      ReadPageInfo(
        mode: ReadMode.local,
        galleryTitle: 'Volume 1',
        initialIndex: 0,
        pageCount: _pages,
        readProgressRecordStorageKey: 'komga:test:book-1',
        images: <GalleryImage?>[
          for (int i = 0; i < _pages; i++)
            GalleryImage(url: '', path: '${files.path}/c1-$i.png', downloadStatus: DownloadStatus.downloaded),
        ],
        useSuperResolution: false,
      ),
    );
  }, skip: _srToolsRoot() == null);

  testWidgets('a downloaded gallery is upscaled as it is read, but for a page still downloading', (WidgetTester tester) async {
    const int gid = 4242;
    galleryDownloadService.galleryDownloadInfos[gid] = GalleryDownloadInfo(
      thumbnailsCountPerPage: 20,
      tasks: <AsyncTask<dynamic>>[],
      cancelToken: CancelToken(),
      downloadProgress: GalleryDownloadProgress(
        curCount: _pages - 1,
        totalCount: _pages,
        downloadStatus: DownloadStatus.downloading,
        hasDownloaded: <bool>[for (int i = 0; i < _pages; i++) i != 3],
      ),
      imageHrefs: <GalleryThumbnail?>[
        for (int i = 0; i < _pages; i++) GalleryThumbnail(href: 'test://1/$i', isLarge: true, thumbUrl: ''),
      ],
      images: <GalleryImage?>[
        for (int i = 0; i < _pages; i++)
          GalleryImage(
            url: 'test://1/$i',
            path: 'c1-$i.png',
            downloadStatus: i == 3 ? DownloadStatus.downloading : DownloadStatus.downloaded,
          ),
      ],
      speedComputer: GalleryDownloadSpeedComputer(_pages, () {}),
      priority: 0,
      sortOrder: 0,
      group: 'default',
    );
    addTearDown(() => galleryDownloadService.galleryDownloadInfos.remove(gid));

    await readUpscaled(
      tester,
      ReadPageInfo(
        mode: ReadMode.downloaded,
        gid: gid,
        token: 'test',
        galleryTitle: 'Gallery',
        galleryUrl: 'https://example.test/g/$gid',
        initialIndex: 0,
        pageCount: _pages,
        readProgressRecordStorageKey: '$gid',
        useSuperResolution: false,
      ),
      upscaled: const <int>[0, 1, 2, 4],
      left: const <int>[3],
    );
  }, skip: _srToolsRoot() == null);
}
