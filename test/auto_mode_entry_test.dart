import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_thumbnail.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/model/read_page_info.dart';
import 'package:jhentai/src/pages/read/read_page.dart';
import 'package:jhentai/src/pages/read/read_page_logic.dart';
import 'package:jhentai/src/pages/setting/read/setting_read_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/gallery_download_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/path_service.dart';
import 'package:jhentai/src/service/read_progress_service.dart';
import 'package:jhentai/src/setting/read_setting.dart';
import 'package:jhentai/src/setting/style_setting.dart';

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

const int _pages = 8;

void main() {
  late Directory files;

  setUpAll(() {
    log = _SilentLogService();
    files = Directory.systemTemp.createTempSync('auto_mode_entry');
    for (int i = 0; i < _pages; i++) {
      final img.Image page = img.Image(width: 300, height: 400);
      img.fill(page, color: img.ColorRgb8(30 * i, 100, 200));
      File('${files.path}/p$i.png').writeAsBytesSync(img.encodePng(page));
    }
    pathService.appDocDir = files;
  });

  tearDownAll(() => files.deleteSync(recursive: true));

  testWidgets('pages turn by themselves, switched on and off in the settings opened from the reader\'s menu', (WidgetTester tester) async {
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    Get.testMode = true;
    Get.put<ReadProgressService>(readProgressService, permanent: true);
    Get.put<GalleryDownloadService>(galleryDownloadService, permanent: true);
    styleSetting.actualLayout = LayoutMode.mobileV2;
    readSetting.readDirection.value = ReadDirection.left2rightSinglePage;
    readSetting.enableBottomMenu.value = false;
    readSetting.keepScreenAwakeWhenReading.value = false;
    readSetting.showThumbnails.value = false;
    readSetting.autoModeInterval.value = 1;
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle',
      (ByteData? message) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );

    final ReadPageInfo book = ReadPageInfo(
      mode: ReadMode.online,
      gid: 1,
      token: 'test',
      galleryTitle: 'Book',
      galleryUrl: 'https://example.test/book/1',
      initialIndex: 0,
      pageCount: _pages,
      readProgressRecordStorageKey: 'book-1',
      thumbnails: <GalleryThumbnail?>[
        for (int i = 0; i < _pages; i++) GalleryThumbnail(href: 'test://1/$i', isLarge: true, thumbUrl: ''),
      ],
      images: <GalleryImage?>[
        for (int i = 0; i < _pages; i++) GalleryImage(url: 'test://1/$i', path: 'p$i.png', downloadStatus: DownloadStatus.downloaded),
      ],
      useSuperResolution: false,
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        GetMaterialApp(
          translations: LocaleText(),
          locale: const Locale('zh', 'CN'),
          home: const Scaffold(),
          getPages: [
            GetPage(name: '/read', page: () => const ReadPage()),
            GetPage(name: Routes.settingRead, page: () => SettingReadPage()),
          ],
        ),
      );
      Get.toNamed('/read', arguments: book);
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
    int page() => reader.state.readPageInfo.currentImageIndex;
    expect(page(), 0);

    Future<void> openSettingsFromMenu() async {
      reader.toggleMenu();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byIcon(Icons.settings));
      await settle();
    }

    // On phones the menu's first row has the brightness lock instead (this
    // host is a desktop, whose menu keeps its own button): the settings
    // opened from the menu have the switch, off.
    await openSettingsFromMenu();
    final Finder autoMode = find.byKey(const Key('autoModeSwitch'));
    expect(autoMode, findsOneWidget);
    expect(find.text('自动翻页'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(autoMode).value, isFalse);

    // Switched on: back on the page, the interval is asked, then pages turn.
    await tester.tap(autoMode);
    await settle();
    expect(find.byType(SettingReadPage), findsNothing);
    expect(find.text('自动模式翻页时间'), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('确定'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await settle();
    expect(reader.state.autoMode, isTrue);
    expect(reader.state.isMenuOpen, isFalse);
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      await settle();
    }
    expect(page(), greaterThanOrEqualTo(2));

    // Switched off from the same place: the pages stay.
    await openSettingsFromMenu();
    expect(tester.widget<SwitchListTile>(autoMode).value, isTrue);
    await tester.tap(autoMode);
    await settle();
    expect(find.byType(SettingReadPage), findsNothing);
    expect(reader.state.autoMode, isFalse);
    final int stopped = page();
    for (int i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
      await settle();
    }
    expect(page(), stopped);

    await tester.runAsync(() async {
      Get.back();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await settle();
    await tester.pump(const Duration(seconds: 16));
    await tester.runAsync(() async {
      Get.reset();
      await appDb.close();
    });
  });

  testWidgets('the settings opened from the app, with no reader open, have no auto mode switch', (WidgetTester tester) async {
    Get.testMode = true;
    addTearDown(Get.reset);
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(GetMaterialApp(home: SettingReadPage()));
    await tester.pump();
    expect(find.byKey(const Key('autoModeSwitch')), findsNothing);
  });
}
