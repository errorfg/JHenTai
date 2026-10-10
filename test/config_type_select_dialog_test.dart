import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/enum/config_type_enum.dart';
import 'package:jhentai/src/widget/eh_config_type_select_dialog.dart';

void main() {
  testWidgets('on a short screen the sync type list scrolls, and its last type can still be unticked', (tester) async {
    tester.view.physicalSize = const Size(400, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    List<CloudConfigTypeEnum>? chosen;
    await tester.pumpWidget(GetMaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              chosen = await showDialog<List<CloudConfigTypeEnum>>(
                context: context,
                builder: (_) => const EHConfigTypeSelectDialog(title: 'selectSyncTypes?'),
              );
            },
            child: const Text('sync now'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('sync now'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'the dialog fits the screen');

    // The last type is below the fold until the list is scrolled.
    final Finder last = find.text(CloudConfigTypeEnum.values.last.name.tr);
    await tester.scrollUntilVisible(
      last,
      100,
      scrollable: find.descendant(of: find.byType(AlertDialog), matching: find.byType(Scrollable)),
    );
    await tester.tap(last);
    await tester.pumpAndSettle();

    // Title and buttons stay on screen while the list scrolls.
    expect(find.text('selectSyncTypes?').hitTestable(), findsOneWidget);
    await tester.tap(find.text('OK').hitTestable());
    await tester.pumpAndSettle();
    expect(chosen, [...CloudConfigTypeEnum.values]..remove(CloudConfigTypeEnum.values.last));
  });
}
