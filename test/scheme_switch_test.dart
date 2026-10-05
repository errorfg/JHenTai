import 'dart:collection';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/gallery.dart';
import 'package:jhentai/src/model/gallery_image.dart';
import 'package:jhentai/src/model/gallery_tag.dart';
import 'package:jhentai/src/model/gallery_url.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/network/jm/jm_models.dart';
import 'package:jhentai/src/pages/favorite/favorite_page_logic.dart';
import 'package:jhentai/src/pages/layout/desktop/desktop_layout_page_state.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/service/jm_favorite_service.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/jm_account_setting.dart';
import 'package:jhentai/src/setting/scheme_setting.dart';

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

/// The home of the app with only the navigation drawer, which is what the
/// scheme switch changes.
class _DrawerHarness extends StatelessWidget {
  const _DrawerHarness();

  @override
  Widget build(BuildContext context) {
    final MobileLayoutPageV2Logic logic = Get.isRegistered<MobileLayoutPageV2Logic>()
        ? Get.find<MobileLayoutPageV2Logic>()
        : Get.put(MobileLayoutPageV2Logic(), permanent: true);
    return Scaffold(
      drawer: MobileLeftDrawer(logic: logic, state: logic.state),
      body: Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => Scaffold.of(context).openDrawer(),
          child: const Text('open drawer'),
        ),
      ),
    );
  }
}

void main() {
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    schemeSetting.site.value = ContentScheme.ehentai;
    jmAccountSetting.applyBeanConfig('{}');
    jmFavoriteService.applyBeanConfig('[]');
    Get.testMode = true;
  });

  tearDown(() async {
    Get.reset();
    schemeSetting.site.value = ContentScheme.ehentai;
    await appDb.close();
  });

  List<TabBarIconNameEnum> mobileTabs() =>
      Get.find<MobileLayoutPageV2Logic>().state.icons.map((icon) => icon.name).toList();

  Future<void> pickScheme(WidgetTester tester, String title) async {
    await tester.tap(find.byKey(const Key('schemePicker')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(title).last);
    await tester.pumpAndSettle();
  }

  testWidgets('the drawer header switches the whole navigation to a site', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (MethodCall call) async => null);

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: const _DrawerHarness(),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('open drawer'));
    await tester.pumpAndSettle();

    expect(mobileTabs(), contains(TabBarIconNameEnum.watched));
    expect(find.text('E-Hentai'), findsOneWidget);

    // The account line sits right under the picker, above the first entry.
    final Rect picker = tester.getRect(find.byKey(const Key('schemePicker')));
    final Rect account = tester.getRect(find.byKey(const Key('schemeAccount')));
    final Rect firstEntry = tester.getRect(find.byKey(const ValueKey<String>('readerMenu:home')));
    expect(account.top, moreOrLessEquals(picker.bottom, epsilon: 4));
    expect(account.left, moreOrLessEquals(picker.left, epsilon: 1));
    expect(account.bottom, lessThan(firstEntry.top));

    await pickScheme(tester, 'JM');
    expect(schemeSetting.site.value, ContentScheme.jm);
    expect(mobileTabs(), <TabBarIconNameEnum>[
      TabBarIconNameEnum.home,
      TabBarIconNameEnum.browse,
      TabBarIconNameEnum.ranklist,
      TabBarIconNameEnum.weekly,
      TabBarIconNameEnum.search,
      TabBarIconNameEnum.favorite,
      TabBarIconNameEnum.history,
      TabBarIconNameEnum.download,
      TabBarIconNameEnum.setting,
    ]);
    // The drawer now lists JM's pages, and its header the JM account.
    expect(find.text('每周必看'), findsOneWidget);
    expect(find.text('点击登录'), findsOneWidget);
    await tester.runAsync(() => jmAccountSetting.saveAccount(const JmUser(id: 1, username: 'reader'), 'AVS=x'));
    await tester.pumpAndSettle();
    expect(find.textContaining('reader'), findsOneWidget);

    await pickScheme(tester, 'nhentai');
    expect(mobileTabs(), <TabBarIconNameEnum>[
      TabBarIconNameEnum.home,
      TabBarIconNameEnum.search,
      TabBarIconNameEnum.popular,
      TabBarIconNameEnum.favorite,
      TabBarIconNameEnum.history,
      TabBarIconNameEnum.download,
      TabBarIconNameEnum.setting,
    ]);

    await pickScheme(tester, 'E-Hentai');
    expect(schemeSetting.site.value, ContentScheme.ehentai);
    expect(mobileTabs(), contains(TabBarIconNameEnum.watched));
  });

  test('the desktop side bar follows the scheme, settings last', () {
    schemeSetting.site.value = ContentScheme.wnacg;
    final List<TabBarIconNameEnum> wnacg = DesktopLayoutPageState().icons.map((icon) => icon.name).toList();
    expect(wnacg, <TabBarIconNameEnum>[
      TabBarIconNameEnum.home,
      TabBarIconNameEnum.search,
      TabBarIconNameEnum.favorite,
      TabBarIconNameEnum.history,
      TabBarIconNameEnum.download,
      TabBarIconNameEnum.setting,
    ]);

    schemeSetting.site.value = ContentScheme.ehentai;
    final List<TabBarIconNameEnum> ehentai = DesktopLayoutPageState().icons.map((icon) => icon.name).toList();
    expect(ehentai.last, TabBarIconNameEnum.setting);
    expect(ehentai, isNot(contains(TabBarIconNameEnum.readerSource)));
  });

  testWidgets('favorites open on the scheme site and follow switches', (WidgetTester tester) async {
    await tester.runAsync(() async {
      await jmFavoriteService.addFavorite(_jmGallery(101), favoriteCategoryIndex: 0);
      await schemeSetting.saveSite(ContentScheme.jm);
    });

    final FavoritePageLogic logic = Get.put(FavoritePageLogic(), permanent: true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(logic.state.showJmFavorites, isTrue);
    expect(logic.state.gallerys.map((Gallery g) => g.gid), <int>[GalleryUrl.jm(101).gid]);

    await tester.runAsync(() => schemeSetting.saveSite(ContentScheme.wnacg));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await tester.pump();
    expect(logic.state.showWnFavorites, isTrue);
    expect(logic.state.showJmFavorites, isFalse);
    expect(logic.state.gallerys, isEmpty);
  });
}

Gallery _jmGallery(int id) => Gallery(
  galleryUrl: GalleryUrl.jm(id),
  title: 'JM $id',
  category: 'Manga',
  cover: GalleryImage(url: 'https://example.test/cover.jpg'),
  pageCount: 10,
  rating: 0,
  hasRated: false,
  language: null,
  uploader: null,
  publishTime: '2026-10-01 10:00',
  isExpunged: false,
  tags: LinkedHashMap<String, List<GalleryTag>>(),
);
