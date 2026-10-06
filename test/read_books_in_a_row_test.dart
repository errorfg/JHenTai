import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
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
}
