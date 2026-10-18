import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/enum/config_enum.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_double_column/horizontal_double_column_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/horizontal_page/horizontal_page_layout_logic.dart';
import 'package:jhentai/src/pages/read/layout/vertical_list/vertical_list_layout_logic.dart';
import 'package:jhentai/src/pages/read/read_page.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/pages/read/spread_pages.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/local_config_service.dart';
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

/// Images 1 and 3 are two pages scanned as one: wider than tall.
const List<bool> _wide = <bool>[false, true, false, true];

/// Online, or from files as local galleries, archives and Komga books are.
ReadPageInfo _book({ReadMode mode = ReadMode.online}) {
  return ReadPageInfo(
    mode: mode,
    gid: 7,
    token: 'test',
    galleryTitle: 'Book',
    galleryUrl: 'https://example.test/book/7',
    initialIndex: 0,
    pageCount: _wide.length,
    readProgressRecordStorageKey: 'book-split',
    thumbnails: mode != ReadMode.online
        ? null
        : <GalleryThumbnail?>[
            for (int i = 0; i < _wide.length; i++) GalleryThumbnail(href: 'test://book/$i', isLarge: true, thumbUrl: ''),
          ],
    images: <GalleryImage?>[
      for (int i = 0; i < _wide.length; i++) GalleryImage(url: 'test://book/$i', path: 'split-$i.png', downloadStatus: DownloadStatus.downloaded),
    ],
    useSuperResolution: false,
  );
}

void main() {
  group('PageParts', () {
    test('a split image takes two pages, each other image one', () {
      final PageParts parts = PageParts(<bool>[false, true, false, true]);
      expect(parts.length, 6);
      expect(<int>[for (int p = 0; p < parts.length; p++) parts.imageOf(p)], <int>[0, 1, 1, 2, 3, 3]);
      expect(<ImagePart>[for (int p = 0; p < parts.length; p++) parts.partOf(p)], <ImagePart>[
        ImagePart.whole,
        ImagePart.first,
        ImagePart.second,
        ImagePart.whole,
        ImagePart.first,
        ImagePart.second,
      ]);
      expect(<int>[for (int i = 0; i < 4; i++) parts.firstPageOf(i)], <int>[0, 1, 3, 4]);
      expect(parts.pageOf(1, ImagePart.second), 2);
      expect(parts.pageOf(2, ImagePart.second), 3, reason: 'an image not split has one page');
    });

    test('unsplit pages are the images', () {
      final PageParts parts = PageParts.unsplit(3);
      expect(parts.length, 3);
      expect(parts.imageOf(2), 2);
      expect(parts.partOf(2), ImagePart.whole);
    });

    test('out-of-range pages and images clamp to the ends', () {
      final PageParts parts = PageParts(<bool>[true, false]);
      expect(parts.imageOf(-1), 0);
      expect(parts.imageOf(9), 1);
      expect(parts.firstPageOf(9), 2);
      expect(PageParts.unsplit(0).imageOf(0), 0);
    });

    test('splitAs compares what is split', () {
      final PageParts parts = PageParts(<bool>[false, true]);
      expect(parts.splitAs(<bool>[false, true]), isTrue);
      expect(parts.splitAs(<bool>[false, false]), isFalse);
      expect(parts.splitAs(<bool>[false, true, false]), isFalse);
    });
  });

  group('the reader', () {
    late Directory files;

    setUpAll(() {
      log = _SilentLogService();
      files = Directory.systemTemp.createTempSync('split_wide_pages');
      for (int i = 0; i < _wide.length; i++) {
        final img.Image page = img.Image(width: _wide[i] ? 600 : 300, height: 400);
        img.fill(page, color: img.ColorRgb8(50 * i, 120, 200));
        File('${files.path}/split-$i.png').writeAsBytesSync(img.encodePng(page));
      }
      pathService.appDocDir = files;
    });

    tearDownAll(() => files.deleteSync(recursive: true));

    Future<void> open(WidgetTester tester, ReadDirection direction, {ReadMode mode = ReadMode.online}) async {
      appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
      Get.testMode = true;
      Get.put<ReadProgressService>(readProgressService, permanent: true);
      Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
      readSetting.readDirection.value = direction;
      readSetting.enableOrientationSpecificReadDirection.value = false;
      readSetting.keepScreenAwakeWhenReading.value = false;
      readSetting.showThumbnails.value = false;
      readSetting.enablePageTurnAnime.value = false;
      readSetting.splitWidePages.value = true;
      readSetting.invertSplitOrder.value = false;
      tester.view.physicalSize = const Size(600, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
        (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(GetMaterialApp(home: const Scaffold(), getPages: [GetPage(name: '/read', page: () => const ReadPage())]));
        Get.toNamed('/read', arguments: _book(mode: mode));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
    }

    Future<void> settle(WidgetTester tester) async {
      for (int i = 0; i < 16; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> close(WidgetTester tester) async {
      await tester.runAsync(() async {
        Get.back();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Closed, so its setting listeners go; Get.reset alone does not close it.
        Get.delete<ReadPageLogic>(force: true);
        Get.reset();
        await appDb.close();
      });
      readSetting.splitWidePages.value = false;
    }

    /// Where the [right] or left half of an image is drawn.
    Rect halfRect(WidgetTester tester, {required bool right}) => tester.getRect(
          find.byWidgetPredicate((Widget w) => w is OverflowBox && w.alignment == (right ? Alignment.centerRight : Alignment.centerLeft)).first,
        );

    bool onScreen(Rect r) => r.left >= -1 && r.right <= 601;

    testWidgets('from right to left, a wide image is two pages, its right half first', (WidgetTester tester) async {
      await open(tester, ReadDirection.right2leftSinglePage);
      await settle(tester);
      final ReadPageLogic reader = Get.find<ReadPageLogic>();
      final HorizontalPageLayoutLogic layout = Get.find<HorizontalPageLayoutLogic>();

      // Image 1 loaded as the next page: found wide, it is two pages now.
      expect(reader.state.spreadPages[1], isTrue);
      expect(layout.parts.firstPageOf(2), 3);

      layout.toNext();
      await settle(tester);
      expect(reader.state.readPageInfo.currentImageIndex, 1);
      expect(layout.parts.partOf(layout.pageController.page!.round()), ImagePart.first);
      expect(onScreen(halfRect(tester, right: true)), isTrue, reason: 'the right half is the page shown');
      // The half is a page of its own: 300 x 400 fitted to the 600 x 800 screen.
      expect(halfRect(tester, right: true).size, const Size(600, 800));

      layout.toNext();
      await settle(tester);
      expect(reader.state.readPageInfo.currentImageIndex, 1, reason: 'both halves are image 1');
      expect(layout.parts.partOf(layout.pageController.page!.round()), ImagePart.second);
      expect(onScreen(halfRect(tester, right: false)), isTrue, reason: 'then the left half');

      layout.toNext();
      await settle(tester);
      expect(reader.state.readPageInfo.currentImageIndex, 2);

      // The wide images found are kept for the book.
      final String? kept = await tester.runAsync<String?>(
        () => localConfigService.read(configKey: ConfigEnum.isSpreadPage, subConfigKey: 'book-split'),
      );
      expect(kept, startsWith('[0,1,0,'));

      // Switched off: one page per image, still on image 2.
      readSetting.splitWidePages.value = false;
      await settle(tester);
      expect(layout.parts.length, _wide.length);
      expect(layout.pageController.page!.round(), 2);
      expect(reader.state.readPageInfo.currentImageIndex, 2);

      // On again, from the slider: image 3 opens on its first half.
      readSetting.splitWidePages.value = true;
      await settle(tester);
      reader.jump2ImageIndex(3);
      await settle(tester);
      expect(reader.state.readPageInfo.currentImageIndex, 3);
      expect(layout.parts.partOf(layout.pageController.page!.round()), ImagePart.first);
      expect(layout.parts.length, 6);

      await close(tester);
    });

    testWidgets('from top to bottom, the halves of a wide image are one above the other', (WidgetTester tester) async {
      await open(tester, ReadDirection.top2bottomList);
      await settle(tester);
      expect(Get.find<ReadPageLogic>().state.spreadPages[1], isTrue);
      Get.find<VerticalListLayoutLogic>().state.itemScrollController.jumpTo(index: 1);
      await settle(tester);

      final Rect right = halfRect(tester, right: true);
      final Rect left = halfRect(tester, right: false);
      expect(right.bottom <= left.top, isTrue, reason: 'the right half is on top');
      // Each half as wide as the page: 300 x 400 fitted to 600 wide.
      expect(right.size, const Size(600, 800));

      readSetting.invertSplitOrder.value = true;
      await settle(tester);
      expect(halfRect(tester, right: false).bottom <= halfRect(tester, right: true).top, isTrue, reason: 'inverted, the left half is on top');

      await close(tester);
    });

    testWidgets('in two columns, a wide image takes a page of its own, kept under the book', (WidgetTester tester) async {
      readSetting.displayFirstPageAlone.value = true;
      await open(tester, ReadDirection.right2leftDoubleColumn);
      await settle(tester);
      final ReadPageLogic reader = Get.find<ReadPageLogic>();
      final HorizontalDoubleColumnLayoutLogic layout = Get.find<HorizontalDoubleColumnLayoutLogic>();
      expect(reader.state.spreadPages[1], isTrue);
      // The cover alone, then image 1 alone, not beside image 2.
      expect(layout.computeImagesInPageIndex(0), <int>[0]);
      expect(layout.computeImagesInPageIndex(1), <int>[1]);
      final String? kept = await tester.runAsync<String?>(
        () => localConfigService.read(configKey: ConfigEnum.isSpreadPage, subConfigKey: 'book-split'),
      );
      expect(kept, startsWith('[0,1,'));

      await close(tester);
    });

    testWidgets('a book read from files is split the same way', (WidgetTester tester) async {
      await open(tester, ReadDirection.right2leftSinglePage, mode: ReadMode.local);
      await settle(tester);
      final ReadPageLogic reader = Get.find<ReadPageLogic>();
      final HorizontalPageLayoutLogic layout = Get.find<HorizontalPageLayoutLogic>();
      expect(reader.state.spreadPages[1], isTrue);
      expect(layout.parts.firstPageOf(2), 3);

      layout.toNext();
      await settle(tester);
      expect(reader.state.readPageInfo.currentImageIndex, 1);
      expect(onScreen(halfRect(tester, right: true)), isTrue);
      expect(halfRect(tester, right: true).size, const Size(600, 800));

      await close(tester);
    });
  });
}
