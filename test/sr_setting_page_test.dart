import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/pages/setting/advanced/super_resolution/setting_super_resolution_page.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

void main() {
  testWidgets('the settings keep the two kinds of upscaling apart and mark the new one experimental', (WidgetTester tester) async {
    Get.testMode = true;
    addTearDown(Get.reset);
    Get.put<SuperResolutionService>(superResolutionService, permanent: true);
    superResolutionSetting = SuperResolutionSetting();
    realtimeSrService = RealtimeSrService()..toolsRootOverride = '/nonexistent';
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: const SettingSuperResolutionPage(),
      ),
    );
    await tester.pump();

    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final Finder offline = find.byKey(const Key('srOfflineSection'));
    final Finder realtime = find.byKey(const Key('srRealtimeSection'));
    final Finder common = find.byKey(const Key('srCommonSection'));

    // Upscaling of downloads: its model folder and model download sit under
    // its own heading, above the new feature.
    expect(find.descendant(of: offline, matching: find.text('已下载内容的超分')), findsOneWidget);
    expect(top(offline), lessThan(top(find.text('模型文件夹路径'))));
    expect(top(find.text('选择模型')), lessThan(top(realtime)));

    // Upscaling while reading: marked experimental, with everything of its
    // own below it, the benchmark included.
    expect(find.descendant(of: realtime, matching: find.text('实时超分')), findsOneWidget);
    expect(find.descendant(of: realtime, matching: find.text('实验性')), findsOneWidget);
    expect(find.descendant(of: offline, matching: find.text('实验性')), findsNothing);
    for (final Finder own in <Finder>[
      find.byKey(const Key('realtimeSrSwitch')),
      find.byKey(const Key('realtimeSrModel')),
      find.text('超分程序: realesrgan'),
      find.text('超分程序: realcugan'),
      find.byKey(const Key('srBenchmark')),
    ]) {
      expect(top(own), greaterThan(top(realtime)));
      expect(top(own), lessThan(top(common)));
    }

    // What both use comes last.
    expect(top(find.text('GPU-id')), greaterThan(top(common)));
  });
}
