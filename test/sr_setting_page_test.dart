import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/database/database.dart';
import 'package:jhentai/src/l18n/locale_text.dart';
import 'package:jhentai/src/pages/setting/advanced/super_resolution/setting_super_resolution_page.dart';
import 'package:jhentai/src/pages/setting/read/setting_read_page.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/service/sr/realtime_sr_service.dart';
import 'package:jhentai/src/service/super_resolution_service.dart';
import 'package:jhentai/src/setting/super_resolution_setting.dart';

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

  testWidgets('the reader\'s settings start with the model and scale of upscaling while reading', (WidgetTester tester) async {
    log = _SilentLogService();
    appDb = (await tester.runAsync(() async => AppDb.forTesting(NativeDatabase.memory())))!;
    addTearDown(() => tester.runAsync(appDb.close));
    Get.testMode = true;
    addTearDown(Get.reset);
    superResolutionSetting = SuperResolutionSetting();
    realtimeSrService = RealtimeSrService()..toolsRootOverride = '/nonexistent';
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      GetMaterialApp(
        translations: LocaleText(),
        locale: const Locale('zh', 'CN'),
        home: SettingReadPage(),
      ),
    );
    await tester.pump();

    double top(Finder finder) => tester.getTopLeft(finder).dy;
    final Finder section = find.byKey(const Key('readRealtimeSrSection'));
    expect(find.descendant(of: section, matching: find.text('实时超分')), findsOneWidget);
    expect(find.descendant(of: section, matching: find.text('实验性')), findsOneWidget);
    // Above the reader's other settings.
    expect(top(section), lessThan(top(find.text('阅读时屏幕不自动锁定'))));
    for (final String key in <String>['realtimeSrSwitch', 'realtimeSrModel', 'realtimeSrScale', 'realtimeSrMaxWidth']) {
      expect(top(find.byKey(Key(key))), greaterThan(top(section)), reason: key);
      expect(top(find.byKey(Key(key))), lessThan(top(find.text('阅读时屏幕不自动锁定'))), reason: key);
    }
    // The program of the chosen model is not installed here: said under it.
    expect(find.text('请先在设置的"超分辨率"中安装所选模型的超分程序'), findsOneWidget);
    // This model has no denoise levels.
    expect(find.byKey(const Key('realtimeSrDenoise')), findsNothing);

    Future<void> choose(String dropdown, String item) async {
      await tester.tap(find.byKey(Key(dropdown)));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text(item).last);
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
    }

    // The scale of the model in use.
    await choose('realtimeSrScale', 'x3');
    expect(superResolutionSetting.realtimeScale.value, 3);

    // Another model: the scale is kept when the model has it, and its
    // denoise levels appear.
    await choose('realtimeSrModel', 'realcugan-se');
    expect(superResolutionSetting.realtimeModel.value, 'realcugan-se');
    expect(superResolutionSetting.realtimeScale.value, 3);
    expect(find.byKey(const Key('realtimeSrDenoise')), findsOneWidget);
    await choose('realtimeSrDenoise', '3');
    expect(superResolutionSetting.realtimeDenoise.value, 3);

    // A model with one scale only: the scale follows it.
    await choose('realtimeSrModel', 'realesrgan-x4plus');
    expect(superResolutionSetting.realtimeScale.value, 4);
    expect(find.byKey(const Key('realtimeSrDenoise')), findsNothing);
  });
}
