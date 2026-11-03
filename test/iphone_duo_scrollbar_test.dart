import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/config/ui_config.dart';
import 'package:jhentai/src/utils/iphone_duo.dart';

void main() {
  tearDown(() => isIPhoneDuo = false);

  /// The padding the scrollbar insets itself by, and the padding its page sees.
  Future<(EdgeInsets, EdgeInsets)> pump(WidgetTester tester, EdgeInsets viewPadding) async {
    FakeViewPadding fake(EdgeInsets padding) => FakeViewPadding(
          left: padding.left * 3,
          top: padding.top * 3,
          right: padding.right * 3,
          bottom: padding.bottom * 3,
        );

    tester.view
      ..devicePixelRatio = 3
      ..physicalSize = const Size(951, 669) * 3
      ..padding = fake(viewPadding)
      ..viewPadding = fake(viewPadding);
    addTearDown(tester.view.reset);

    late EdgeInsets pagePadding;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            scrollBehavior: UIConfig.scrollBehaviourWithScrollBarWithMouse,
            slivers: [
              SliverToBoxAdapter(
                child: Builder(
                  builder: (BuildContext context) {
                    pagePadding = MediaQuery.paddingOf(context);
                    return const SizedBox(height: 5000);
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return (MediaQuery.paddingOf(tester.element(find.byWidgetPredicate((Widget widget) => widget is RawScrollbar))), pagePadding);
  }

  testWidgets(
    'iPhone Duo: the scrollbar stays at the screen edge, the page keeps its padding',
    (WidgetTester tester) async {
      isIPhoneDuo = true;

      final (EdgeInsets scrollbar, EdgeInsets page) = await pump(tester, const EdgeInsets.only(right: 84));

      expect(find.byType(CupertinoScrollbar), findsOneWidget);
      expect(scrollbar.right, 0);
      expect(page.right, 84);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'iPhone Duo: folding keeps what the scrollbar holds in place',
    (WidgetTester tester) async {
      isIPhoneDuo = true;

      await pump(tester, const EdgeInsets.only(right: 84));
      final State<StatefulWidget> before = tester.state(find.byType(Scrollable));
      final Element viewport = tester.element(find.byType(Viewport));

      await pump(tester, const EdgeInsets.only(top: 82, bottom: 34));

      expect(tester.state(find.byType(Scrollable)), same(before));
      expect(tester.element(find.byType(Viewport)), same(viewport));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'another iPhone on its side: the scrollbar stays clear of the notch',
    (WidgetTester tester) async {
      final (EdgeInsets scrollbar, _) = await pump(tester, const EdgeInsets.only(left: 62, right: 62));

      expect(scrollbar.right, 62);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'a camera cutout on one side on Android: the scrollbar stays clear of it',
    (WidgetTester tester) async {
      final (EdgeInsets scrollbar, _) = await pump(tester, const EdgeInsets.only(right: 40));

      expect(scrollbar.right, 40);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
}
