import 'package:drift/native.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/model/content_scheme.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/pages/komga/komga_page.dart';
import 'package:jhentai/src/pages/komga/komga_settings_page.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/komga_setting.dart';
import 'package:jhentai/src/setting/scheme_setting.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/widget/scheme_header.dart';

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

class _DesktopNavigatorHarness extends StatelessWidget {
  const _DesktopNavigatorHarness();

  @override
  Widget build(BuildContext context) {
    return Navigator(
      key: Get.nestedKey(42),
      onGenerateRoute: (_) => MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/desktop-fixture'),
        builder: (_) => const SizedBox.shrink(),
      ),
    );
  }
}

class _MobileHomeHarness extends StatelessWidget {
  const _MobileHomeHarness();

  @override
  Widget build(BuildContext context) {
    if (!Get.isRegistered<MobileLayoutPageV2Logic>()) {
      Get.put(MobileLayoutPageV2Logic(), permanent: true);
    }
    return const Scaffold(body: Center(child: Text('EH mobile home')));
  }
}

void main() {
  // The Komga page saves itself as the page open (SchemeSetting.ownPage).
  setUp(() {
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
  });
  tearDown(() => appDb.close());

  testWidgets('unconfigured Komga opens settings above a desktop navigator', (
    WidgetTester tester,
  ) async {
    final KomgaSetting originalKomgaSetting = komgaSetting;
    komgaSetting = KomgaSetting();
    Get.testMode = true;
    await tester.binding.setSurfaceSize(const Size(1280, 800));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      komgaSetting = originalKomgaSetting;
      Get.reset();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: Routes.home,
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        transitionDuration: Duration.zero,
        getPages: [
          GetPage(
            name: Routes.home,
            page: _DesktopNavigatorHarness.new,
            transition: Transition.noTransition,
          ),
          GetPage(
            name: Routes.komga,
            page: KomgaPage.new,
            transition: Transition.noTransition,
          ),
          GetPage(
            name: Routes.komgaSettings,
            page: KomgaSettingsPage.new,
            transition: Transition.noTransition,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    Get.toNamed<dynamic>(Routes.komga);
    await tester.pumpAndSettle();

    expect(find.byType(KomgaPage), findsOneWidget);
    expect(find.byType(KomgaSettingsPage), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, '配置 Komga'));
    await tester.pumpAndSettle();

    expect(find.byType(KomgaSettingsPage), findsOneWidget);
    expect(Get.currentRoute, Routes.komgaSettings);
  });

  testWidgets('Komga drawer destination returns home and selects the EH tab', (
    WidgetTester tester,
  ) async {
    final KomgaSetting originalKomgaSetting = komgaSetting;
    final LayoutMode originalActualLayout = styleSetting.actualLayout;
    komgaSetting = KomgaSetting();
    styleSetting.actualLayout = LayoutMode.mobileV2;
    Get.testMode = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      komgaSetting = originalKomgaSetting;
      styleSetting.actualLayout = originalActualLayout;
      Get.reset();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: Routes.home,
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        transitionDuration: Duration.zero,
        getPages: [
          GetPage(
            name: Routes.home,
            page: _MobileHomeHarness.new,
            transition: Transition.noTransition,
          ),
          GetPage(
            name: Routes.komga,
            page: KomgaPage.new,
            transition: Transition.noTransition,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    Get.toNamed<dynamic>(Routes.komga);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(CupertinoIcons.sidebar_left));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('readerMenu:history')));
    await tester.pumpAndSettle();

    expect(Get.currentRoute, Routes.home);
    expect(find.text('EH mobile home'), findsOneWidget);
    final MobileLayoutPageV2Logic layoutLogic =
        Get.find<MobileLayoutPageV2Logic>();
    expect(
      layoutLogic.state.icons[layoutLogic.state.selectedDrawerTabIndex].name,
      TabBarIconNameEnum.history,
    );
  });

  testWidgets('Komga is a peer of the sites: back and swipe stay on it, and it opens again at start until a site is picked', (
    WidgetTester tester,
  ) async {
    final KomgaSetting originalKomgaSetting = komgaSetting;
    final LayoutMode originalActualLayout = styleSetting.actualLayout;
    komgaSetting = KomgaSetting();
    styleSetting.actualLayout = LayoutMode.mobileV2;
    schemeSetting.site.value = ContentScheme.ehentai;
    schemeSetting.ownPage.value = null;
    Get.testMode = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));

    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      komgaSetting = originalKomgaSetting;
      styleSetting.actualLayout = originalActualLayout;
      schemeSetting.ownPage.value = null;
      Get.reset();
    });

    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: Routes.home,
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        transitionDuration: Duration.zero,
        getPages: [
          GetPage(
            name: Routes.home,
            page: _MobileHomeHarness.new,
            transition: Transition.noTransition,
          ),
          GetPage(
            name: Routes.komga,
            page: KomgaPage.new,
            transition: Transition.noTransition,
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    await switchScheme(ContentScheme.ehentai, ContentScheme.komga);
    await tester.pumpAndSettle();
    expect(find.byType(KomgaPage), findsOneWidget);
    expect(schemeSetting.ownPage.value, ContentScheme.komga);

    // No swipe back to the site, and the system back stays.
    final ModalRoute<dynamic> route = ModalRoute.of(tester.element(find.byType(KomgaPage)))!;
    expect(route.popDisposition, RoutePopDisposition.doNotPop);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(Get.currentRoute, Routes.komga);

    // Saved on this device: what the next start reads.
    final SchemeSetting restarted = SchemeSetting()..applyBeanConfig(schemeSetting.toConfigString());
    expect((restarted.site.value, restarted.ownPage.value), (ContentScheme.ehentai, ContentScheme.komga));
    expect((SchemeSetting()..applyBeanConfig('{"site":"jm","ownPage":"nhentai"}')).ownPage.value, isNull, reason: 'only Komga and PDF have pages of their own');

    await switchScheme(ContentScheme.komga, ContentScheme.ehentai);
    await tester.pumpAndSettle();
    expect(find.text('EH mobile home'), findsOneWidget);
    expect(schemeSetting.ownPage.value, isNull, reason: 'a site picked: the next start shows the site');

    // As at a start after leaving the app on Komga: over the home.
    await schemeSetting.openOwnPage(ContentScheme.komga);
    reopenOwnPage();
    await tester.pumpAndSettle();
    expect(find.byType(KomgaPage), findsOneWidget);
    expect(Get.currentRoute, Routes.komga);
    expect(find.text('EH mobile home', skipOffstage: false), findsOneWidget);
  });
}
