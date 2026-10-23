import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/pages/komga/komga_page.dart';
import 'package:jhentai/src/routes/routes.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/komga_setting.dart';

import 'support/e2e_app.dart';
import 'support/local_komga.dart';

class _HomeHarness extends StatelessWidget {
  const _HomeHarness();

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('site home'));
}

/// Lets the requests to Komga answer, then draws, until [found] shows.
Future<void> _waitFor(WidgetTester tester, Finder found) async {
  for (int i = 0; i < 100 && found.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(found, findsWidgets);
}

/// Menus morph open and closed; lets the morph finish.
Future<void> _morph(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Opens the sort and filter menu of the bar and picks [path], submenus first.
Future<void> _pickFromMenu(WidgetTester tester, List<String> path) async {
  await tester.tap(find.byWidgetPredicate((Widget w) =>
      w is Icon &&
      (w.icon == CupertinoIcons.line_horizontal_3_decrease_circle ||
          w.icon == CupertinoIcons.line_horizontal_3_decrease_circle_fill)));
  await _morph(tester);
  for (final String item in path) {
    await tester.tap(find.text(item).last);
    await _morph(tester);
  }
}

/// Whether [a] comes before [b] in the grid: by row, then by column.
bool _before(WidgetTester tester, String a, String b) {
  final Offset pa = tester.getTopLeft(find.text(a).first), pb = tester.getTopLeft(find.text(b).first);
  return pa.dy < pb.dy - 1 || ((pa.dy - pb.dy).abs() <= 1 && pa.dx < pb.dx);
}

/// The Komga page as a phone shows it, against a real Komga: the glass bar's
/// sort and filter menu, the series/books switch at the bottom, and back.
void main() {
  final KomgaE2eConfig? config = KomgaE2eConfig.load();
  if (config == null) {
    test('Komga page e2e', () {}, skip: 'test/e2e/komga_e2e.json is absent');
    return;
  }

  late LocalKomga komga;
  late E2eDevice device;

  setUpAll(() async {
    // Widget tests answer every request with 400 unless let through.
    HttpOverrides.global = null;
    log = SilentLogService();
    komga = await LocalKomga.start(config);
    device = E2eDevice()..activate();
  });

  tearDownAll(() async {
    await device.close();
    await komga.stop();
  });

  Future<void> browse(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        initialRoute: Routes.home,
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        getPages: <GetPage>[
          GetPage(name: Routes.home, page: _HomeHarness.new, transition: Transition.noTransition),
          GetPage(name: Routes.komga, page: () => KomgaPage(clientFactory: () => e2eClient(komga)), transition: Transition.noTransition),
        ],
      ),
    );
    Get.toNamed<dynamic>(Routes.komga);
    await _waitFor(tester, find.text('E2E'));
    await tester.tap(find.text('E2E'));
    // The home's shelves show the series too: first the library's level.
    await _waitFor(tester, find.byIcon(CupertinoIcons.back));
    await _waitFor(tester, find.text(TestLibrary.gamma));

    await _pickFromMenu(tester, <String>['标题']);
    await _waitFor(tester, find.text(TestLibrary.alpha));
    expect(_before(tester, TestLibrary.alpha, TestLibrary.beta) && _before(tester, TestLibrary.beta, TestLibrary.gamma), isTrue, reason: 'by title, A to Z');

    // The current order again reverses it.
    await _pickFromMenu(tester, <String>['标题']);
    await _waitFor(tester, find.text(TestLibrary.alpha));
    expect(_before(tester, TestLibrary.gamma, TestLibrary.beta) && _before(tester, TestLibrary.beta, TestLibrary.alpha), isTrue, reason: 'by title, Z to A');

    // Nothing is read yet: read only leaves nothing, and the button fills.
    await _pickFromMenu(tester, <String>['阅读状态', '已读']);
    await _waitFor(tester, find.text('没有符合当前筛选条件的内容'));
    expect(find.byIcon(CupertinoIcons.line_horizontal_3_decrease_circle_fill), findsOneWidget);

    await _pickFromMenu(tester, <String>['清除全部筛选']);
    await _waitFor(tester, find.text(TestLibrary.alpha));
    expect(find.byIcon(CupertinoIcons.line_horizontal_3_decrease_circle), findsOneWidget);

    await tester.tap(find.text('全部书籍'));
    await _waitFor(tester, find.textContaining(' vol '));

    // Back goes up inside Komga, then stays: Komga is not on top of a site.
    await tester.binding.handlePopRoute();
    await _waitFor(tester, find.text('E2E'));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(KomgaPage), findsOneWidget);
    expect(Get.currentRoute, Routes.komga);

    // Its timers run out once the page is gone; idle HTTP connections
    // close after 15 seconds.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 16));
  }

  testWidgets('a library is ordered and narrowed from the sort and filter menu, switched to books at the bottom, and back stays in Komga', (WidgetTester tester) async {
    HttpOverrides.global = null;
    Get.testMode = true;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    final KomgaSetting original = komgaSetting;
    komgaSetting = KomgaSetting()
      ..serverUrl.value = komga.serverUrl
      ..apiKey.value = komga.apiKey
      ..connectionId.value = 'e2e';
    addTearDown(() async {
      await tester.binding.setSurfaceSize(null);
      komgaSetting = original;
      Get.reset();
    });

    // The test library's Gamma series has no thumbnail Flutter can decode.
    final FlutterExceptionHandler? onError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.library != 'image resource service') {
        onError?.call(details);
      }
    };
    try {
      await browse(tester);
    } finally {
      FlutterError.onError = onError;
    }
  });
}
