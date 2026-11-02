import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/model/jh_layout.dart';
import 'package:jhentai/src/model/tab_bar_icon.dart';
import 'package:jhentai/src/pages/gallerys/dashboard/dashboard_page.dart';
import 'package:jhentai/src/pages/home_page.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_logic.dart';
import 'package:jhentai/src/pages/layout/mobile_v2/mobile_layout_page_v2_state.dart';
import 'package:jhentai/src/pages/layout/tablet_v2/tablet_layout_page_v2.dart';
import 'package:jhentai/src/pages/search/quick_search/quick_search_page.dart';
import 'package:jhentai/src/setting/advanced_setting.dart';
import 'package:jhentai/src/setting/style_setting.dart';
import 'package:jhentai/src/utils/iphone_duo.dart';
import 'package:liquid_glass_widgets/src/widgets/surfaces/vertical_bar_regions.dart';

/// The window and insets iOS 27.1 gives an app in a pose of the device.
class _Pose {
  const _Pose(this.name, this.size, this.viewPadding);

  final String name;
  final Size size;
  final EdgeInsets viewPadding;
}

const _Pose _innerFlat = _Pose('inner display, open flat', Size(951, 669), EdgeInsets.only(right: 84));
const _Pose _outer = _Pose('outer display', Size(466, 678), EdgeInsets.only(right: 84));
const _Pose _upright = _Pose('inner display, upright', Size(669, 951), EdgeInsets.only(top: 82, bottom: 34));
const _Pose _outerLeft = _Pose('outer display, strip on the left', Size(678, 466), EdgeInsets.only(left: 84));
const _Pose _outerRight = _Pose('outer display, strip on the right', Size(678, 466), EdgeInsets.only(right: 84));

const List<TabBarIconNameEnum> _destinations = [
  TabBarIconNameEnum.home,
  TabBarIconNameEnum.search,
  TabBarIconNameEnum.popular,
  TabBarIconNameEnum.ranklist,
  TabBarIconNameEnum.favorite,
  TabBarIconNameEnum.watched,
  TabBarIconNameEnum.history,
  TabBarIconNameEnum.download,
  TabBarIconNameEnum.setting,
];

/// The padding the page on screen is given.
EdgeInsets? _pagePadding;

/// The native views asked for, by view type.
final List<String> _nativeViews = <String>[];

List<TabBarIcon> _icons() => _destinations
    .map(
      (TabBarIconNameEnum name) => TabBarIcon(
        name: name,
        routeName: '/${name.name}',
        selectedIcon: const Icon(Icons.star),
        unselectedIcon: const Icon(Icons.star_border),
        page: () => Builder(
          builder: (BuildContext context) {
            _pagePadding = MediaQuery.paddingOf(context);
            return SizedBox.expand(key: ValueKey<String>('page:${name.name}'), child: Text('page:${name.name}'));
          },
        ),
        shouldRender: name == TabBarIconNameEnum.home,
      ),
    )
    .toList();

void _setPose(WidgetTester tester, _Pose pose) {
  FakeViewPadding fake(EdgeInsets padding) => FakeViewPadding(
        left: padding.left * 3,
        top: padding.top * 3,
        right: padding.right * 3,
        bottom: padding.bottom * 3,
      );

  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = pose.size * 3;
  tester.view.padding = fake(pose.viewPadding);
  tester.view.viewPadding = fake(pose.viewPadding);
  addTearDown(tester.view.reset);
}

MobileLayoutPageV2Logic _putLogic() {
  final MobileLayoutPageV2Logic logic = Get.put(MobileLayoutPageV2Logic(), permanent: true);
  logic.state.icons = _icons();
  logic.state.selectedDrawerTabIndex = 0;
  return logic;
}

Future<MobileLayoutPageV2Logic> _pumpHome(WidgetTester tester, _Pose pose) async {
  _setPose(tester, pose);
  final MobileLayoutPageV2Logic logic = _putLogic();

  await tester.pumpWidget(GetMaterialApp(home: MobileLayoutPageV2()));
  await tester.pumpAndSettle();
  return logic;
}

Finder _tab(TabBarIconNameEnum name) => find.byKey(ValueKey<String>('sideRail:${name.name}'));

final Finder _bar = find.byKey(const ValueKey<String>('mobileSideRail'));
final Finder _tabs = find.byKey(const ValueKey<String>('sideRail:tabs'));
final Finder _menuButton = find.byKey(const ValueKey<String>('sideRail:panel'));
final Finder _panel = find.byKey(const ValueKey<String>('mobileLeftDrawer'));

ScaffoldState get _scaffold => MobileLayoutPageV2State.scaffoldKey.currentState!;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    isIPhoneDuo = true;
    MobileLayoutPageV2State.scaffoldKey = GlobalKey();
    _nativeViews.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, (MethodCall call) async {
      if (call.method == 'create') {
        _nativeViews.add((call.arguments as Map<Object?, Object?>)['viewType'] as String);
      }
      return null;
    });
  });

  tearDown(() {
    isIPhoneDuo = false;
    VerticalBarRegions.instance.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform_views, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('liquid_glass_widgets/reserved_regions'), null);
    Get.reset();
  });

  void expectStrip(WidgetTester tester, _Pose pose, {required double top, required double bottom}) {
    expect(find.byType(NavigationBar), findsNothing);

    final Rect bar = tester.getRect(_bar);
    final bool atLeft = pose.viewPadding.left > 0;
    expect(bar.width, 84);
    expect(atLeft ? bar.left : bar.right, atLeft ? 0 : pose.size.width);

    // A column 48 wide, 24 from the edge, as the system's.
    final Rect menu = tester.getRect(_menuButton);
    expect(menu.width, 48);
    expect(menu.center.dx, atLeft ? 48 : pose.size.width - 48);
    expect(menu.top, top);
    expect(tester.getRect(_tabs).bottom, pose.size.height - bottom);
    expect(tester.getRect(_tabs).top, greaterThanOrEqualTo(menu.bottom));

    // The page stops at the bar, and does not leave room for it again.
    final Rect page = tester.getRect(find.byKey(const ValueKey<String>('page:home')));
    expect(atLeft ? page.left : page.right, atLeft ? bar.right : bar.left);
    expect(atLeft ? _pagePadding!.left : _pagePadding!.right, 0);
  }

  group('the bar goes where the system puts its own', () {
    testWidgets(_innerFlat.name, (WidgetTester tester) async {
      await _pumpHome(tester, _innerFlat);
      expectStrip(tester, _innerFlat, top: 120, bottom: 24);
    });

    testWidgets(_outer.name, (WidgetTester tester) async {
      await _pumpHome(tester, _outer);
      expectStrip(tester, _outer, top: 170, bottom: 24);
    });

    testWidgets(_outerLeft.name, (WidgetTester tester) async {
      await _pumpHome(tester, _outerLeft);
      expectStrip(tester, _outerLeft, top: 82, bottom: 24);
    });

    testWidgets(_outerRight.name, (WidgetTester tester) async {
      await _pumpHome(tester, _outerRight);
      expectStrip(tester, _outerRight, top: 24, bottom: 82);
    });

    testWidgets('${_upright.name}: along the top, beside the status bar', (WidgetTester tester) async {
      await _pumpHome(tester, _upright);

      expect(find.byType(NavigationBar), findsNothing);

      // Inside the page's top inset, left of the status bar's corner.
      final Rect menu = tester.getRect(_menuButton);
      final Rect tabs = tester.getRect(_tabs);
      expect(menu.left, 20);
      expect(menu.top, 24);
      expect(menu.bottom, 72);
      expect(tabs.top, 24);
      expect(tabs.bottom, 72);
      expect(tabs.left, greaterThanOrEqualTo(menu.right));
      expect(tabs.right, lessThanOrEqualTo(669 - 134));

      // The page keeps its whole width and the inset.
      expect(tester.getRect(find.byKey(const ValueKey<String>('page:home'))).width, 669);
      expect(_pagePadding!.top, 82);

      // All of them show without scrolling.
      for (final TabBarIconNameEnum name in _destinations) {
        expect(tester.getRect(_tab(name)).right, lessThanOrEqualTo(tabs.right));
      }
    });

    testWidgets('the regions iOS reports come before the measured ones', (WidgetTester tester) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('liquid_glass_widgets/reserved_regions'), (MethodCall call) async {
        return call.method == 'observe'
            ? <Object>[
                <Object>[867.0, 0.0, 951.0, 140.0, 0],
              ]
            : null;
      });

      await _pumpHome(tester, _innerFlat);
      await tester.pumpAndSettle();

      expect(tester.getRect(_menuButton).top, 140);
    });
  });

  testWidgets('the bar is drawn on iOS\'s own glass', (WidgetTester tester) async {
    await _pumpHome(tester, _innerFlat);

    expect(_nativeViews, <String>['jhentai/native_glass', 'jhentai/native_glass']);

    await tester.tap(_menuButton);
    await tester.pumpAndSettle();

    expect(_nativeViews, hasLength(3));
  });

  testWidgets('tapping a tab switches the page', (WidgetTester tester) async {
    final MobileLayoutPageV2Logic logic = await _pumpHome(tester, _innerFlat);

    await tester.tap(_tab(TabBarIconNameEnum.favorite));
    await tester.pumpAndSettle();

    expect(logic.state.selectedDrawerTabIndex, _destinations.indexOf(TabBarIconNameEnum.favorite));
    expect(find.text('page:favorite'), findsOneWidget);
    expect(find.text('page:home'), findsNothing);
  });

  testWidgets('where the tabs do not fit, they scroll along the bar', (WidgetTester tester) async {
    await _pumpHome(tester, _outerRight);

    final double before = tester.getRect(_tab(TabBarIconNameEnum.popular)).top;
    await tester.drag(_tabs, const Offset(0, -100));
    await tester.pumpAndSettle();

    expect(tester.getRect(_tab(TabBarIconNameEnum.popular)).top, lessThan(before));
    expect(_scaffold.isEndDrawerOpen, isFalse);
  });

  testWidgets('dragging out of the tabs pulls out the menu card, under the finger', (WidgetTester tester) async {
    await _pumpHome(tester, _innerFlat);

    final Offset start = tester.getCenter(_tabs);
    final TestGesture gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(-120, 0));
    await tester.pump();

    // Partway: as far as the finger has gone.
    final double partway = tester.getRect(_panel).left;
    expect(partway, greaterThan(951 - 362));
    expect(partway, lessThan(951));

    await gesture.moveBy(const Offset(-300, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(_scaffold.isEndDrawerOpen, isTrue);
    expect(find.byType(QuickSearchPage), findsNothing);
  });

  testWidgets('the menu button opens the card; choosing in it closes it', (WidgetTester tester) async {
    final MobileLayoutPageV2Logic logic = await _pumpHome(tester, _innerFlat);

    await tester.tap(_menuButton);
    await tester.pumpAndSettle();

    expect(_scaffold.isEndDrawerOpen, isTrue);
    final Rect panel = tester.getRect(_panel);
    expect(panel.right, 951);
    expect(panel.width, 278 + 84);

    // Clear of the status bar along the edge.
    final Finder history = find.byKey(ValueKey<String>('readerMenu:${TabBarIconNameEnum.history.name}'));
    expect(tester.getRect(history).right, lessThanOrEqualTo(951 - 84));

    await tester.tap(history);
    await tester.pumpAndSettle();

    expect(_scaffold.isEndDrawerOpen, isFalse);
    expect(logic.state.selectedDrawerTabIndex, _destinations.indexOf(TabBarIconNameEnum.history));
  });

  testWidgets('with the bar on the left, the menu button opens the card on the left', (WidgetTester tester) async {
    await _pumpHome(tester, _outerLeft);

    await tester.tap(_menuButton);
    await tester.pumpAndSettle();

    expect(_scaffold.isDrawerOpen, isTrue);
    expect(tester.getRect(_panel).left, 0);
    expect(tester.getRect(_panel).width, 278 + 84);
  });

  testWidgets('the layout setting does not apply: always the phone layout', (WidgetTester tester) async {
    _setPose(tester, _innerFlat);

    final LayoutMode savedLayout = styleSetting.layout.value;
    final bool savedClipboard = advancedSetting.enableCheckClipboard.value;
    addTearDown(() {
      styleSetting.layout.value = savedLayout;
      advancedSetting.enableCheckClipboard.value = savedClipboard;
    });
    styleSetting.layout.value = LayoutMode.tabletV2;
    advancedSetting.enableCheckClipboard.value = false;

    _putLogic();

    await tester.pumpWidget(GetMaterialApp(home: const HomePage()));
    await tester.pumpAndSettle();

    expect(find.byType(MobileLayoutPageV2), findsOneWidget);
    expect(find.byType(TabletLayoutPageV2), findsNothing);
    expect(styleSetting.actualLayout, LayoutMode.mobileV2);
  });

  test('the dashboard has no button for quick search', () {
    final Iterable<IconData?> icons = const DashboardPage().buildAppBarActions().whereType<IconButton>().map((IconButton button) => (button.icon as Icon).icon);

    expect(icons, isNot(contains(Icons.more_vert)));
  });

  test('on other phones the dashboard keeps its button for quick search', () {
    isIPhoneDuo = false;
    final Iterable<IconData?> icons = const DashboardPage().buildAppBarActions().whereType<IconButton>().map((IconButton button) => (button.icon as Icon).icon);

    expect(icons, contains(Icons.more_vert));
  });
}
