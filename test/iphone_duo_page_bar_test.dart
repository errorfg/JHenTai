import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/pages/komga/komga_page.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/utils/iphone_duo.dart';
import 'package:jhentai/src/widget/iphone_duo_bar.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/vertical_bar_regions.dart';

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

const Size _outer = Size(466, 678);
const EdgeInsets _outerPadding = EdgeInsets.only(right: 84, bottom: 34);
const Size _upright = Size(669, 951);
const EdgeInsets _uprightPadding = EdgeInsets.only(top: 82, bottom: 34);

final Finder _strip = find.byKey(const ValueKey<String>('mobileSideRail'));
final Finder _actions = find.byKey(const ValueKey<String>('sideRail:actions'));
final Finder _panel = find.byKey(const ValueKey<String>('mobileLeftDrawer'));
final Finder _panelButton = find.byKey(const ValueKey<String>('komgaPanelButton'));
final Finder _moreMenu = find.byKey(const ValueKey<String>('komgaMoreMenu'));

void _setPose(WidgetTester tester, Size size, EdgeInsets padding) {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = size * 3;
  tester.view.padding = FakeViewPadding(left: padding.left * 3, top: padding.top * 3, right: padding.right * 3, bottom: padding.bottom * 3);
  tester.view.viewPadding = tester.view.padding;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    isIPhoneDuo = true;
    log = _SilentLogService();
    appDb = AppDb.forTesting(NativeDatabase.memory());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (MethodCall call) async => null);
  });

  tearDown(() async {
    isIPhoneDuo = false;
    VerticalBarRegions.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    Get.reset();
    await appDb.close();
  });

  group('a page with the strip to itself', () {
    Future<void> pumpPage(WidgetTester tester, Size size, EdgeInsets padding, {required List<bool> inStrip}) async {
      _setPose(tester, size, padding);
      await tester.pumpWidget(MaterialApp(
        home: IPhoneDuoBar(
          controls: (_) => IPhoneDuoPageControls(
            navigation: const [BackButton()],
            actions: [IconButton(icon: const Icon(Icons.search), onPressed: () {}), IconButton(icon: const Icon(Icons.filter_alt_outlined), onPressed: () {})],
          ),
          builder: (BuildContext context, bool controlsInStrip) {
            inStrip.add(controlsInStrip);
            return const Scaffold(key: ValueKey<String>('page'), body: SizedBox.expand());
          },
        ),
      ));
      await tester.pump();
    }

    testWidgets('outer display: navigation on top, then the actions, in the strip', (WidgetTester tester) async {
      final List<bool> inStrip = [];
      await pumpPage(tester, _outer, _outerPadding, inStrip: inStrip);

      expect(inStrip.last, isTrue);
      expect(tester.getRect(_strip).width, 84);
      expect(tester.getRect(_strip).right, _outer.width);
      expect(tester.getRect(find.byKey(const ValueKey<String>('page'))).right, _outer.width - 84);

      final Rect back = tester.getRect(find.byType(BackButton));
      final Rect search = tester.getRect(find.byIcon(Icons.search));
      final Rect filter = tester.getRect(find.byIcon(Icons.filter_alt_outlined));
      expect(search.top, greaterThan(back.bottom));
      expect(filter.top, greaterThan(search.bottom));
      expect(tester.getRect(_actions).height, 2 * 50 + 12);
    });

    testWidgets('inner display upright: the page keeps its own bar, as the system does', (WidgetTester tester) async {
      final List<bool> inStrip = [];
      await pumpPage(tester, _upright, _uprightPadding, inStrip: inStrip);

      expect(inStrip.last, isFalse);
      expect(_strip, findsNothing);
      expect(find.byType(BackButton), findsNothing);
    });
  });

  group('Komga', () {
    Future<void> pumpKomga(WidgetTester tester, Size size, EdgeInsets padding) async {
      _setPose(tester, size, padding);
      await tester.pumpWidget(const GetMaterialApp(home: KomgaPage()));
      await tester.pump();
    }

    testWidgets('outer display: its controls are in the strip, and the panel opens on the right', (WidgetTester tester) async {
      await pumpKomga(tester, _outer, _outerPadding);

      expect(tester.getRect(_strip).right, _outer.width);
      expect(find.descendant(of: _strip, matching: _panelButton), findsOneWidget);
      expect(find.descendant(of: _strip, matching: _moreMenu), findsOneWidget);

      await tester.tap(_panelButton);
      await tester.pumpAndSettle();
      expect(tester.getRect(_panel).right, _outer.width);
    });

    testWidgets('the menu in the strip opens, on screen', (WidgetTester tester) async {
      await pumpKomga(tester, _outer, _outerPadding);

      await tester.tap(find.descendant(of: _moreMenu, matching: find.byType(IconButton)));
      await tester.pumpAndSettle();

      final Finder settings = find.text('komgaSettings');
      expect(settings, findsOneWidget);
      final Rect rect = tester.getRect(settings);
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(_outer.width));
      expect(rect.bottom, lessThanOrEqualTo(_outer.height));
    });

    testWidgets('inner display upright: the bar at the top stays, with the panel still on the right', (WidgetTester tester) async {
      await pumpKomga(tester, _upright, _uprightPadding);

      expect(_strip, findsNothing);
      expect(_moreMenu, findsNothing);

      final ScaffoldState scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      expect(scaffold.hasDrawer, isFalse);
      expect(scaffold.hasEndDrawer, isTrue);
    });

    testWidgets('on other phones nothing changes: the drawer is on the left and there is no strip', (WidgetTester tester) async {
      isIPhoneDuo = false;
      await pumpKomga(tester, const Size(402, 874), const EdgeInsets.only(top: 62, bottom: 34));

      expect(_strip, findsNothing);
      final ScaffoldState scaffold = tester.state<ScaffoldState>(find.byType(Scaffold).first);
      expect(scaffold.hasDrawer, isTrue);
      expect(scaffold.hasEndDrawer, isFalse);
    });
  });
}
