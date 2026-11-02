import 'package:flutter/material.dart';
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

/// The window and safe area the system gives the app in a pose of the device.
class _Pose {
  const _Pose(this.name, this.size, this.padding, {required this.railTop, required this.railWidth, this.fits = true});

  final String name;
  final Size size;
  final EdgeInsets padding;

  /// Nothing of the rail above this: the status bar and camera are there.
  final double railTop;
  final double railWidth;

  /// Whether the whole rail fits without scrolling.
  final bool fits;
}

const _Pose _innerFlat = _Pose('inner display, open flat', Size(951, 669), EdgeInsets.only(right: 84), railTop: 119, railWidth: 84);

const List<_Pose> _poses = [
  _innerFlat,
  _Pose('outer display', Size(466, 678), EdgeInsets.only(right: 84), railTop: 169, railWidth: 84),
  _Pose('inner display, upright', Size(669, 951), EdgeInsets.only(top: 82), railTop: 82, railWidth: 72),
  _Pose('outer display, on its side', Size(678, 466), EdgeInsets.only(left: 84), railTop: 0, railWidth: 72, fits: false),
];

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

/// The right padding the page on screen is given.
double? _pageRightPadding;

List<TabBarIcon> _icons() => _destinations
    .map(
      (TabBarIconNameEnum name) => TabBarIcon(
        name: name,
        routeName: '/${name.name}',
        selectedIcon: const Icon(Icons.star),
        unselectedIcon: const Icon(Icons.star_border),
        page: () => Builder(
          builder: (BuildContext context) {
            _pageRightPadding = MediaQuery.paddingOf(context).right;
            return SizedBox.expand(key: ValueKey<String>('page:${name.name}'), child: Text('page:${name.name}'));
          },
        ),
        shouldRender: name == TabBarIconNameEnum.home,
      ),
    )
    .toList();

Future<MobileLayoutPageV2Logic> _pumpHome(WidgetTester tester, _Pose pose) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = pose.size * 3;
  tester.view.padding = FakeViewPadding(
    left: pose.padding.left * 3,
    top: pose.padding.top * 3,
    right: pose.padding.right * 3,
    bottom: pose.padding.bottom * 3,
  );
  addTearDown(tester.view.reset);

  final MobileLayoutPageV2Logic logic = Get.put(MobileLayoutPageV2Logic(), permanent: true);
  logic.state.icons = _icons();
  logic.state.selectedDrawerTabIndex = 0;

  await tester.pumpWidget(GetMaterialApp(home: MobileLayoutPageV2()));
  await tester.pumpAndSettle();
  return logic;
}

Finder _railItem(TabBarIconNameEnum name) => find.byKey(ValueKey<String>('sideRail:${name.name}'));

final Finder _rail = find.byKey(const ValueKey<String>('mobileSideRail'));
final Finder _panelButton = find.byKey(const ValueKey<String>('sideRail:panel'));

ScaffoldState get _scaffold => MobileLayoutPageV2State.scaffoldKey.currentState!;

void main() {
  setUp(() {
    isIPhoneDuo = true;
    MobileLayoutPageV2State.scaffoldKey = GlobalKey();
  });

  tearDown(() {
    isIPhoneDuo = false;
    Get.reset();
  });

  for (final _Pose pose in _poses) {
    testWidgets('${pose.name}: the rail takes the place of the bottom bar', (WidgetTester tester) async {
      await _pumpHome(tester, pose);

      expect(find.byType(NavigationBar), findsNothing);

      final Rect rail = tester.getRect(_rail);
      expect(rail.right, pose.size.width);
      expect(rail.width, pose.railWidth);
      expect(tester.getRect(_panelButton).top, greaterThanOrEqualTo(pose.railTop));

      // The page stops at the rail, and does not leave room for it again.
      expect(tester.getRect(find.byKey(const ValueKey<String>('page:home'))).right, lessThanOrEqualTo(rail.left));
      expect(_pageRightPadding, 0);

      await tester.scrollUntilVisible(_railItem(TabBarIconNameEnum.setting), 48, scrollable: find.descendant(of: _rail, matching: find.byType(Scrollable)));
      await tester.pumpAndSettle();
      final Rect last = tester.getRect(_railItem(TabBarIconNameEnum.setting));
      expect(last.bottom, lessThanOrEqualTo(pose.size.height));

      if (pose.fits) {
        expect(tester.getRect(_railItem(TabBarIconNameEnum.home)).top, greaterThanOrEqualTo(tester.getRect(_panelButton).bottom));
      }
    });
  }

  testWidgets('along the system inset, the buttons line up under the status bar', (WidgetTester tester) async {
    await _pumpHome(tester, _innerFlat);

    // Apple's bar: a column 48 wide, 24 from the edge.
    expect(tester.getRect(_panelButton).center.dx, 951 - 24 - 24);
    expect(tester.getRect(_railItem(TabBarIconNameEnum.home)).center.dx, 951 - 24 - 24);
  });

  testWidgets('tapping the rail switches the page', (WidgetTester tester) async {
    final MobileLayoutPageV2Logic logic = await _pumpHome(tester, _innerFlat);

    await tester.tap(_railItem(TabBarIconNameEnum.favorite));
    await tester.pumpAndSettle();

    expect(logic.state.selectedDrawerTabIndex, _destinations.indexOf(TabBarIconNameEnum.favorite));
    expect(find.text('page:favorite'), findsOneWidget);
    expect(find.text('page:home'), findsNothing);
  });

  testWidgets('the rail button opens the panel; choosing in it closes the panel', (WidgetTester tester) async {
    final MobileLayoutPageV2Logic logic = await _pumpHome(tester, _innerFlat);

    await tester.tap(_panelButton);
    await tester.pumpAndSettle();

    expect(_scaffold.isEndDrawerOpen, isTrue);
    final Rect panel = tester.getRect(find.byKey(const ValueKey<String>('mobileLeftDrawer')));
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

  testWidgets('a swipe in from the right edge opens the panel, not quick search', (WidgetTester tester) async {
    await _pumpHome(tester, _innerFlat);

    await tester.dragFrom(const Offset(951 - 4, 300), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(_scaffold.isEndDrawerOpen, isTrue);
    expect(find.byKey(const ValueKey<String>('mobileLeftDrawer')), findsOneWidget);
    expect(find.byType(QuickSearchPage), findsNothing);
  });

  testWidgets('the layout setting does not apply: always the phone layout', (WidgetTester tester) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = const Size(951, 669) * 3;
    addTearDown(tester.view.reset);

    final LayoutMode savedLayout = styleSetting.layout.value;
    final bool savedClipboard = advancedSetting.enableCheckClipboard.value;
    addTearDown(() {
      styleSetting.layout.value = savedLayout;
      advancedSetting.enableCheckClipboard.value = savedClipboard;
    });
    styleSetting.layout.value = LayoutMode.tabletV2;
    advancedSetting.enableCheckClipboard.value = false;

    final MobileLayoutPageV2Logic logic = Get.put(MobileLayoutPageV2Logic(), permanent: true);
    logic.state.icons = _icons();
    logic.state.selectedDrawerTabIndex = 0;

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
