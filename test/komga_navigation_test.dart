import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/pages/komga/komga_page.dart';
import 'package:jhentai/src/pages/komga/komga_settings_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/setting/komga_setting.dart';

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

void main() {
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
}
