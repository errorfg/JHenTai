import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
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
import 'package:jhentai/src/setting/read_setting.dart';

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
}
