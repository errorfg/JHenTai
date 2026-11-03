import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:liquid_glass_widgets/widgets/shared/glass_selection_lens.dart';

/// The vendored liquid_glass_widgets shows the item under a pressing finger
/// with a glass lens instead of a white fill (third_party/liquid_glass_widgets/PATCHES.md).
void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  Rect? lensRect(WidgetTester tester, Finder within) =>
      tester.widget<GlassSelectionLens>(find.descendant(of: within, matching: find.byType(GlassSelectionLens))).rect;

  testWidgets('Pressing and sliding across a button group moves the lens and activates the item it ends on', (WidgetTester tester) async {
    final List<String> taps = <String>[];
    await tester.pumpWidget(host(
      GlassButtonGroup.icons(
        items: <GlassButtonGroupItem>[
          GlassButtonGroupItem(icon: const Icon(CupertinoIcons.sidebar_left), onTap: () => taps.add('sidebar')),
          GlassButtonGroupItem(icon: const Icon(CupertinoIcons.search), onTap: () => taps.add('search')),
          GlassButtonGroupItem(icon: const Icon(CupertinoIcons.ellipsis), onTap: () => taps.add('more')),
        ],
      ),
    ));
    final Finder group = find.byType(GlassButtonGroup);
    final Offset sidebar = tester.getCenter(find.byIcon(CupertinoIcons.sidebar_left));
    final Offset more = tester.getCenter(find.byIcon(CupertinoIcons.ellipsis));

    expect(lensRect(tester, group), isNull);

    // A plain tap is the item's own tap, once.
    await tester.tapAt(sidebar);
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, <String>['sidebar']);

    // The lens lies over the pressed item and follows the finger.
    final TestGesture slide = await tester.startGesture(sidebar);
    await tester.pump();
    final Rect overSidebar = lensRect(tester, group)!;
    expect(overSidebar.left, 0);
    expect(overSidebar.size, tester.getSize(find.byIcon(CupertinoIcons.sidebar_left)) + const Offset(24, 24));
    await slide.moveTo(more);
    await tester.pump();
    final Rect overMore = lensRect(tester, group)!;
    expect(overMore.center.dx, greaterThan(overSidebar.center.dx));
    expect(overMore.width, overSidebar.width);
    await slide.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, <String>['sidebar', 'more']);
    expect(lensRect(tester, group), isNull);

    // Sliding off the group cancels: no lens, nothing activated.
    final TestGesture away = await tester.startGesture(sidebar);
    await tester.pump();
    await away.moveTo(sidebar + const Offset(0, 120));
    await tester.pump();
    expect(lensRect(tester, group), isNull);
    await away.up();
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, <String>['sidebar', 'more']);
  });

  testWidgets('A menu shows the row under the finger with the lens, not a fill', (WidgetTester tester) async {
    final List<String> taps = <String>[];
    await tester.pumpWidget(host(
      GlassButtonGroup.icons(
        items: <GlassButtonGroupItem>[
          GlassButtonGroupItem.menu(
            icon: const Icon(CupertinoIcons.ellipsis),
            menuItems: <Widget>[
              GlassMenuItem(title: 'First', onTap: () => taps.add('first')),
              GlassMenuItem(title: 'Second', onTap: () => taps.add('second')),
            ],
          ),
        ],
      ),
    ));
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Second'), findsOneWidget);

    final Finder menu = find.byType(GlassMenu);
    final Finder menuLens = find.descendant(of: menu, matching: find.byType(GlassSelectionLens));
    Rect? rowLens() => tester.widgetList<GlassSelectionLens>(menuLens).map((GlassSelectionLens lens) => lens.rect).whereType<Rect>().firstOrNull;

    final TestGesture press = await tester.startGesture(tester.getCenter(find.text('First')));
    await tester.pump(const Duration(milliseconds: 50));
    final Rect overFirst = rowLens()!;
    await press.moveTo(tester.getCenter(find.text('Second')));
    await tester.pump(const Duration(milliseconds: 50));
    final Rect overSecond = rowLens()!;
    expect(overSecond.top, greaterThan(overFirst.top));

    // The row under the finger grows below the lens; no flat highlight is drawn.
    final AnimatedScale secondScale = tester.widget<AnimatedScale>(
      find.ancestor(of: find.text('Second'), matching: find.byType(AnimatedScale)).first,
    );
    expect(secondScale.scale, greaterThan(1));
    expect(
      find.descendant(
        of: menu,
        matching: find.byWidgetPredicate((Widget w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).color == const Color(0x3DFFFFFF)),
      ),
      findsNothing,
    );

    await press.up();
    await tester.pump(const Duration(milliseconds: 800));
    expect(taps, <String>['second']);
  });
}
